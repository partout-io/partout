// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! A small serial actor executor.
//!
//! The actor owns a worker thread and a FIFO mailbox. Synchronous calls enqueue
//! stack-backed jobs and wait for completion; asynchronous posts enqueue
//! heap-backed jobs and return immediately.

const std = @import("std");

const concurrency = @import("concurrency.zig");

pub fn Actor(
    comptime Context: type,
    comptime Message: type,
    comptime Error: type,
    comptime perform: fn (*Context, Message) Error!void,
) type {
    return struct {
        const Self = @This();
        const Command = union(enum) {
            message: Message,
            shutdown,
        };

        const Result = union(enum) {
            ok,
            err: Error,
            closed,
        };

        const Outcome = struct {
            result: Result = .ok,
            exit: bool = false,
        };

        const Job = struct {
            command: Command,
            next: ?*Job = null,
            owned: bool = false,
            done: bool = false,
            result: Result = .ok,
        };

        pub const CreateError = std.mem.Allocator.Error || std.Thread.SpawnError;
        pub const PostError = std.mem.Allocator.Error || error{Closed};
        pub const CallError = Error || error{Closed};

        /// Replaces the condition-backed mailbox wait. `wait` must block until
        /// work may be available, and returns `false` when the actor must exit.
        /// `wake_up` must make an in-flight `wait` return. Both callbacks
        /// execute without the actor mutex held.
        pub const WaitCallbacks = struct {
            wait: *const fn (*Context) bool,
            wake_up: *const fn (*Context) void,
        };

        allocator: std.mem.Allocator,
        context: *Context,
        mutex: concurrency.Mutex = .{},
        cond: concurrency.Condition = .{},
        thread: ?std.Thread = null,
        thread_id: ?std.Thread.Id = null,
        accepting: bool = false,
        head: ?*Job = null,
        tail: ?*Job = null,
        wait_callbacks: ?WaitCallbacks = null,
        worker_exited: bool = false,

        pub fn create(allocator: std.mem.Allocator, context: *Context) CreateError!*Self {
            return createWithWaitCallbacks(allocator, context, null);
        }

        pub fn createWithWaitCallbacks(
            allocator: std.mem.Allocator,
            context: *Context,
            wait_callbacks: ?WaitCallbacks,
        ) CreateError!*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .context = context,
                .accepting = true,
                .wait_callbacks = wait_callbacks,
            };
            errdefer {
                self.cond.deinit();
                self.mutex.deinit();
                allocator.destroy(self);
            }

            self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.shutdown();
            self.cond.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }

        fn isCurrentThreadLocked(self: *const Self) bool {
            const thread_id = self.thread_id orelse return false;
            return thread_id == std.Thread.getCurrentId();
        }

        pub fn isCurrentThread(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.isCurrentThreadLocked();
        }

        /// Dispatches a message asynchronously with the actor.
        pub fn post(self: *Self, message: Message) PostError!void {
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

        /// Dispatches a message synchronously with the actor. Returns
        /// a domain-specific error related to the job execution.
        pub fn call(self: *Self, message: Message) CallError!void {
            var job = Job{ .command = .{ .message = message } };

            // Watch out for recursive locks. If we are invoking call()
            // on the actor thread, e.g., as the effect of a nested
            // call(), we must execute the job immediately. Waiting on
            // the condition would lead to a deadlock.
            self.mutex.lock();
            if (self.isCurrentThreadLocked()) {
                self.mutex.unlock();
                return perform(self.context, message);
            }
            defer self.mutex.unlock();

            if (!self.accepting) return error.Closed;
            self.pushLocked(&job);
            while (!job.done) {
                self.cond.wait(&self.mutex);
            }
            return switch (job.result) {
                .ok => {},
                .err => |err| err,
                .closed => error.Closed,
            };
        }

        /// Stops the actor thread after already queued work completes.
        pub fn shutdown(self: *Self) void {
            var job = Job{ .command = .shutdown };

            self.mutex.lock();
            const thread = self.thread orelse {
                self.mutex.unlock();
                return;
            };
            if (self.worker_exited) {
                self.thread = null;
                self.thread_id = null;
                self.mutex.unlock();
                thread.join();
                return;
            }
            // Stop accepting new jobs
            self.accepting = false;
            self.pushLocked(&job);
            while (!job.done) {
                self.cond.wait(&self.mutex);
            }
            // Only after shutdown dispatch do we clean up
            self.thread = null;
            self.thread_id = null;
            self.mutex.unlock();

            // Wait for pending jobs
            thread.join();
        }

        /// Pushes to the queue while inside the mutex.
        fn pushLocked(self: *Self, job: *Job) void {
            job.next = null;
            if (self.tail) |tail| {
                tail.next = job;
            } else {
                self.head = job;
            }
            self.tail = job;
            self.cond.broadcast();
            if (self.wait_callbacks) |callbacks| {
                // The callback is required to be non-blocking. Calling it
                // outside this mutex also permits it to re-enter the context.
                self.mutex.unlock();
                callbacks.wake_up(self.context);
                self.mutex.lock();
            }
        }

        fn popBlocking(self: *Self) ?*Job {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null) {
                if (self.wait_callbacks) |callbacks| {
                    self.mutex.unlock();
                    const should_continue = callbacks.wait(self.context);
                    self.mutex.lock();
                    if (!should_continue) return null;
                } else {
                    self.cond.wait(&self.mutex);
                }
            }
            const job = self.head.?;
            self.head = job.next;
            if (self.head == null) {
                self.tail = null;
            }
            job.next = null;
            return job;
        }

        fn run(self: *Self) void {
            self.mutex.lock();
            self.thread_id = std.Thread.getCurrentId();
            self.cond.broadcast();
            self.mutex.unlock();

            while (true) {
                const job = self.popBlocking() orelse break;
                const outcome = self.performCommand(job.command);

                self.mutex.lock();
                job.result = outcome.result;
                job.done = true;
                self.cond.broadcast();
                self.mutex.unlock();

                const should_exit = outcome.exit;
                if (job.owned) {
                    self.allocator.destroy(job);
                }
                if (should_exit) break;
            }

            self.mutex.lock();
            self.accepting = false;
            self.worker_exited = true;
            self.closePendingLocked();
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn closePendingLocked(self: *Self) void {
            var current = self.head;
            self.head = null;
            self.tail = null;
            while (current) |job| {
                const next = job.next;
                job.next = null;
                job.result = .closed;
                job.done = true;
                if (job.owned) self.allocator.destroy(job);
                current = next;
            }
        }

        fn performCommand(self: *Self, command: Command) Outcome {
            switch (command) {
                .message => |message| {
                    perform(self.context, message) catch |err| {
                        return .{ .result = .{ .err = err } };
                    };
                },
                .shutdown => return .{ .exit = true },
            }
            return .{};
        }
    };
}
