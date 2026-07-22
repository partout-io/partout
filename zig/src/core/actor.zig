// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! A small serial actor executor.
//!
//! The actor owns a worker thread and a FIFO mailbox. `perform` enqueues
//! stack-backed jobs and waits for completion; `schedule` enqueues heap-backed
//! jobs and returns immediately.

const std = @import("std");

const concurrency = @import("concurrency.zig");

pub fn Actor(
    comptime Context: type,
    comptime Message: type,
    comptime Error: type,
    comptime handler: fn (*Context, Message) Error!void,
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
        pub const ScheduleError = std.mem.Allocator.Error || error{Closed};
        pub const PerformError = Error || error{Closed};

        allocator: std.mem.Allocator,
        context: *Context,
        mutex: concurrency.Mutex = .{},
        cond: concurrency.Condition = .{},
        thread: ?std.Thread = null,
        thread_id: ?std.Thread.Id = null,
        accepting: bool = false,
        head: ?*Job = null,
        tail: ?*Job = null,

        pub fn create(allocator: std.mem.Allocator, context: *Context) CreateError!*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .context = context,
                .accepting = true,
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

        fn isCurrentThread(self: *const Self) bool {
            const thread_id = self.thread_id orelse return false;
            return thread_id == std.Thread.getCurrentId();
        }

        /// Schedules a message asynchronously on the actor.
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

        /// Performs a message synchronously on the actor. Returns
        /// a domain-specific error related to the job execution.
        pub fn perform(self: *Self, message: Message) PerformError!void {
            var job = Job{ .command = .{ .message = message } };

            // Watch out for recursive locks. If we are invoking perform()
            // on the actor thread, e.g., as the effect of a nested
            // perform(), we must execute the job immediately. Waiting on
            // the condition would lead to a deadlock.
            self.mutex.lock();
            if (self.isCurrentThread()) {
                self.mutex.unlock();
                return handler(self.context, message);
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
        }

        fn popBlocking(self: *Self) *Job {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null) {
                self.cond.wait(&self.mutex);
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
                const job = self.popBlocking();
                const outcome = self.performCommand(job.command);
                // Snapshot ownership before publishing completion. A synchronous
                // caller may return and invalidate its stack-backed job as soon
                // as done is signalled.
                const owned = job.owned;

                self.mutex.lock();
                job.result = outcome.result;
                job.done = true;
                self.cond.broadcast();
                self.mutex.unlock();

                const should_exit = outcome.exit;
                if (owned) {
                    self.allocator.destroy(job);
                }
                if (should_exit) return;
            }
        }

        fn performCommand(self: *Self, command: Command) Outcome {
            switch (command) {
                .message => |message| {
                    handler(self.context, message) catch |err| {
                        return .{ .result = .{ .err = err } };
                    };
                },
                .shutdown => return .{ .exit = true },
            }
            return .{};
        }
    };
}
