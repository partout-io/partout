// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! A small serial actor executor.
//!
//! The actor owns a worker thread and a FIFO mailbox. `perform` enqueues
//! stack-backed jobs and waits for completion; `schedule` enqueues heap-backed
//! jobs and returns immediately.
//! A custom driver can poll I/O between jobs and replace the worker's idle wait.
//! Synchronous callers still use the condition variable for job completion.
//!
//! The handler has signature `fn (*Context, comptime Result: type, Message)
//! Error!Result`. Each `perform` call chooses its result type; scheduled messages
//! invoke the handler with `void`.

const std = @import("std");

const concurrency = @import("concurrency.zig");
const util = @import("util.zig");

const Fifo = util.Fifo;

/// Pass null for the driver type to use DefaultDriver.
pub fn ActorWithoutFinish(
    comptime Context: type,
    comptime OptionalDriver: ?type,
    comptime Message: type,
    comptime Error: type,
    comptime handler: anytype,
) type {
    return Actor(Context, OptionalDriver, Message, Error, handler, null);
}

/// Pass null for the driver type to use DefaultDriver. A custom driver is
/// initialized with the shared mailbox mutex and Context pointer.
/// It provides init(), deinit(), wait(), notify(), wake(), resetWake(), and
/// loopOnce(context, max_wait_ms). Custom-driver contexts and external resources
/// must be ready before create() and remain valid through shutdown().
///
/// wait() releases/reacquires the shared mutex while waiting for completion;
/// notify() wakes completion waiters. wake() and resetWake() run with that same
/// mutex held, must not call actor APIs, and must preserve a wake until consumed
/// or reset. loopOnce() runs on the worker outside the mutex: zero polls, null
/// may block until I/O, a timer, or wake(). It may perform nested actor work and
/// must handle its own I/O failures, returning on wake so shutdown can proceed.
pub fn Actor(
    comptime Context: type,
    comptime OptionalDriver: ?type,
    comptime Message: type,
    comptime Error: type,
    comptime handler: anytype,
    comptime on_finish: ?*const fn (*Context) void,
) type {
    return struct {
        const Self = @This();
        const Command = union(enum) {
            message: Message,
            perform: struct {
                context: *anyopaque,
                callback: *const fn (*Context, *anyopaque) Error!void,
            },
            shutdown,
        };

        const Outcome = struct {
            result: Error!void = {},
            exit: bool = false,
        };

        const Job = struct {
            command: Command,
            next: ?*Job = null,
            owned: bool = false,
            done: bool = false,
            result: Error!void = {},
        };

        pub const CreateError = std.mem.Allocator.Error || std.Thread.SpawnError;
        pub const ScheduleError = std.mem.Allocator.Error || error{Closed};
        pub const PerformError = Error || error{Closed};

        pub const Driver = OptionalDriver orelse DefaultDriver;

        allocator: std.mem.Allocator,
        context: *Context,
        driver: Driver,
        mutex: concurrency.Mutex,
        thread: ?std.Thread,
        thread_id: ?std.Thread.Id,
        accepting: bool,
        jobs: Fifo(Job),

        pub fn create(allocator: std.mem.Allocator, context: *Context) CreateError!*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .context = context,
                .driver = undefined,
                .mutex = .{},
                .thread = null,
                .thread_id = null,
                .accepting = true,
                .jobs = .{},
            };
            self.driver = Driver.init(&self.mutex, context);
            errdefer {
                self.driver.deinit();
                self.mutex.deinit();
                allocator.destroy(self);
            }

            self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.shutdown();
            self.driver.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }

        fn isCurrentThread(self: *const Self) bool {
            const thread_id = self.thread_id orelse return false;
            return thread_id == std.Thread.getCurrentId();
        }

        pub fn isOnQueue(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.isCurrentThread();
        }

        /// Schedules a message asynchronously with a void result.
        pub fn schedule(self: *Self, message: Message) ScheduleError!void {
            const job = try self.allocator.create(Job);
            errdefer self.allocator.destroy(job);
            job.* = .{
                .command = .{ .message = message },
                .owned = true,
            };

            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.accepting) return error.Closed;
            self.pushLocked(job);
        }

        /// Performs a message synchronously on the actor, returning the handler's
        /// result or a domain-specific error related to the job execution.
        pub fn perform(self: *Self, comptime Result: type, message: Message) PerformError!Result {
            const Request = struct {
                message: Message,
                result: Result = undefined,

                fn call(context: *Context, opaque_request: *anyopaque) Error!void {
                    const request: *@This() = @ptrCast(@alignCast(opaque_request));
                    request.result = try handler(context, Result, request.message);
                }
            };
            var request = Request{ .message = message };
            var job = Job{ .command = .{ .perform = .{
                .context = &request,
                .callback = Request.call,
            } } };

            // Watch out for recursive locks. If we are invoking perform()
            // on the actor thread, e.g., as the effect of a nested
            // perform(), we must execute the job immediately. Waiting on
            // the condition would lead to a deadlock.
            self.mutex.lock();
            if (self.isCurrentThread()) {
                self.mutex.unlock();
                return handler(self.context, Result, message);
            }
            defer self.mutex.unlock();

            if (!self.accepting) return error.Closed;
            self.pushLocked(&job);
            while (!job.done) {
                self.driver.wait();
            }
            try job.result;
            return request.result;
        }

        /// Stops the actor thread after already queued work completes.
        pub fn shutdown(self: *Self) void {
            var job = Job{ .command = .shutdown };

            self.mutex.lock();
            const thread = self.thread orelse {
                self.mutex.unlock();
                return;
            };
            // Stop accepting new jobs
            self.accepting = false;
            self.pushLocked(&job);
            while (!job.done) {
                self.driver.wait();
            }
            // Stop exposing the join handle, but retain the worker identity
            // until its terminal callback has completed. This lets that
            // callback perform nested actor work inline while shutdown joins.
            self.thread = null;
            self.mutex.unlock();

            // Wait for pending jobs
            thread.join();

            self.mutex.lock();
            self.thread_id = null;
            self.mutex.unlock();
        }

        /// Pushes to the queue while inside the mutex.
        fn pushLocked(self: *Self, job: *Job) void {
            self.jobs.append(job);
            self.driver.wake();
        }

        fn pop(self: *Self) ?*Job {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.jobs.take();
        }

        fn drive(self: *Self) void {
            self.mutex.lock();
            self.driver.resetWake();
            const has_jobs = self.jobs.head != null;
            self.mutex.unlock();

            // Enqueueing after the check leaves a wake pending. Never hold the
            // mailbox mutex while polling, waiting, or invoking I/O callbacks.
            self.driver.loopOnce(self.context, if (has_jobs) 0 else null);
        }

        fn run(self: *Self) void {
            defer if (on_finish) |callback| callback(self.context);

            self.mutex.lock();
            self.thread_id = std.Thread.getCurrentId();
            self.driver.notify();
            self.mutex.unlock();

            while (true) {
                if (self.pop()) |job| {
                    const outcome = self.performCommand(job.command);
                    // Snapshot ownership before publishing completion. A synchronous
                    // caller may return and invalidate its stack-backed job as soon
                    // as done is signalled.
                    const owned = job.owned;

                    self.mutex.lock();
                    job.result = outcome.result;
                    job.done = true;
                    self.driver.notify();
                    self.mutex.unlock();

                    if (owned) self.allocator.destroy(job);
                    if (outcome.exit) return;
                }
                self.drive();
            }
        }

        fn performCommand(self: *const Self, command: Command) Outcome {
            switch (command) {
                .message => |message| return .{ .result = handler(self.context, void, message) },
                .perform => |request| return .{ .result = request.callback(self.context, request.context) },
                .shutdown => return .{ .exit = true },
            }
        }
    };
}

/// Default worker wake and synchronous job-completion waits. The actor owns
/// the shared mailbox mutex; this driver owns the condition variable.
/// wait(), notify(), wake(), and resetWake() require the mutex to be held.
/// Deinitialize only after the worker and completion waiters have finished.
pub const DefaultDriver = struct {
    mutex: *concurrency.Mutex,
    condition: concurrency.Condition = .{},
    signalled: bool = false,

    pub fn init(mutex: *concurrency.Mutex, _: anytype) DefaultDriver {
        return .{ .mutex = mutex };
    }

    pub fn deinit(self: *DefaultDriver) void {
        self.condition.deinit();
    }

    pub fn wait(self: *DefaultDriver) void {
        self.condition.wait(self.mutex);
    }

    pub fn notify(self: *DefaultDriver) void {
        self.condition.broadcast();
    }

    pub fn wake(self: *DefaultDriver) void {
        self.signalled = true;
        self.notify();
    }

    pub fn resetWake(self: *DefaultDriver) void {
        self.signalled = false;
    }

    pub fn loopOnce(self: *DefaultDriver, _: anytype, max_wait_ms: ?u32) void {
        if (max_wait_ms != null) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Completion broadcasts do not mean that mailbox work is available.
        while (!self.signalled) self.wait();
    }
};
