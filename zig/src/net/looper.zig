// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Serial, mux-backed I/O loop for a link descriptor and a tunnel descriptor.
//!
//! `Looper` is the Zig counterpart of Darwin's `FdLooper`. The object must stay
//! at a stable address from `start()` until `stop()`/`deinit()` has completed.
//! Callback contexts are borrowed and must outlive the attachment (or the
//! looper itself for `OnFinish`). Packet slices passed to callbacks are borrowed
//! for the duration of the callback. Slices returned by `TransformWrite` must
//! remain valid until the enclosing `write()` call returns; `Looper` copies them
//! before queuing them.

const std = @import("std");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const queue_mod = @import("looper_queue.zig");
const c = io.c;
const log = core.logging;

pub const Looper = struct {
    /// Max number of attached sides.
    const number_of_descriptors = 2;
    /// Hardcoded delay on backpressure (ENOBUFS).
    const no_buf_retry_delay_ms = 10;

    // Scheduling.
    pub const Packet = queue_mod.Packet;
    pub const Packets = queue_mod.Packets;
    pub const ReadAction = queue_mod.ReadAction;
    pub const TransformWrite = queue_mod.TransformWrite;
    pub const OnRead = queue_mod.OnRead;
    pub const Failure = queue_mod.Failure;
    pub const OnFailure = queue_mod.OnFailure;
    pub const OnFinish = queue_mod.OnFinish;
    pub const Task = queue_mod.Task;

    // Side attachment.
    pub const Descriptor = queue_mod.Descriptor;
    pub const DescriptorPair = queue_mod.DescriptorPair;
    pub const AttachArguments = queue_mod.AttachArguments;

    // Queues.
    const SideIdentity = queue_mod.SideIdentity;
    const Completion = queue_mod.Completion;
    const CompletionQueue = queue_mod.CompletionQueue;
    const Command = queue_mod.Command;
    const CommandNode = queue_mod.CommandNode;
    const CommandQueue = queue_mod.CommandQueue;
    const WriteQueue = queue_mod.WriteQueue;

    /// Looper state.
    const State = enum {
        idle,
        starting,
        started,
        stopping,
        stopped,
        deinitializing,
    };

    /// Outcome of a command submission (caller-side).
    const CommandOutcome = struct {
        should_continue: bool = true,
        failure: ?Failure = null,
    };

    /// Outcome of a command execution (worker-side).
    const ProcessOutcome = union(enum) {
        ok,
        side_failure: struct {
            side: io.Side,
            failure: Failure,
        },
        fatal: Failure,
    };

    /// Fine-tuning.
    pub const Options = struct {
        link_buf_size: usize = 64 * 1024,
        tun_buf_size: usize = 16 * 1024,
        max_read_size: usize = 256 * 1024,
        max_read_count: usize = 128,
        on_finish: OnFinish,
    };

    const Errors = queue_mod.Errors;
    const SubmissionError = std.mem.Allocator.Error || Errors.Cancelled;
    const CompletionError = queue_mod.CompletionError;
    pub const InitError = std.mem.Allocator.Error || Errors.MuxFailure;
    pub const StartError = std.mem.Allocator.Error ||
        std.Thread.SpawnError ||
        Errors.AlreadyStarted;
    pub const AttachError = SubmissionError ||
        Errors.MuxFailure ||
        Errors.OperationCancelled ||
        Errors.ReentrantCall;
    pub const DetachError = SubmissionError || Errors.ReentrantCall;
    pub const ResumeReadingError = SubmissionError;
    pub const ScheduleError = SubmissionError || Errors.TaskFailure;
    pub const StopError = SubmissionError ||
        Errors.InvalidState ||
        Errors.ReentrantCall ||
        Errors.TerminalFailure;
    pub const WriteError = SubmissionError ||
        io.Error ||
        Errors.TransformFailure ||
        Errors.WriteIncomplete;

    // Configuration.
    allocator: std.mem.Allocator,
    options: Options,

    // Lifecycle synchronization.
    lock: core.Mutex = .{},
    condition: core.Condition = .{},
    state: State = .idle,
    terminal_failure: ?Failure = null,

    // Command submission and synchronous completion.
    commands: CommandQueue = .{},
    completions: CompletionQueue = .{},
    stop_completion: ?*Completion = null,
    waiter_count: usize = 0,

    // Delayed command scheduler.
    scheduler: core.RunAfter = .{},

    // Mux-owned resources.
    mux: c.pp_mux,
    fd_set: ?DescriptorSet = null,

    // Attached sides and their scheduled retries.
    link: ?*SideIO = null,
    tun: ?*SideIO = null,
    next_side_id: u64 = 1,
    // The size of these follows `number_of_descriptors`.
    read_retries: [2]bool = .{ false, false },
    write_retries: [2]bool = .{ false, false },

    // Worker ownership and identity.
    worker_thread: ?std.Thread = null,
    loop_thread_id: ?std.Thread.Id = null,

    /// Prevents deadlock on callback reentrancy.
    threadlocal var borrowed_callback_depth: usize = 0;

    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        const mux = c.pp_mux_create(number_of_descriptors) orelse {
            log.writef(.err, "Unable to create mux", .{});
            return error.MuxFailure;
        };
        var resolved_options = options;
        resolved_options.max_read_size = @max(
            options.max_read_size,
            @max(options.link_buf_size, options.tun_buf_size),
        );
        return .{
            .allocator = allocator,
            .options = resolved_options,
            .mux = mux,
        };
    }

    pub fn deinit(self: *Looper) void {
        log.writef(.debug, "Deinit Looper", .{});

        if (self.isReentrantLifecycleCall()) {
            @panic("Looper.deinit() must run outside looper callbacks");
        }

        self.lock.lock();
        while (self.state == .starting) {
            self.condition.wait(&self.lock);
        }
        const cleanup_in_deinit = self.state == .idle;
        const should_wake_worker = self.state == .started or self.state == .stopping;
        self.state = .deinitializing;

        self.cancelPendingLocked(self.commands.takeReady());
        self.read_retries = .{ false, false };
        self.write_retries = .{ false, false };
        if (self.stop_completion) |completion| {
            completeNow(completion, error.Cancelled);
            self.stop_completion = null;
        }
        self.releaseCompletionsLocked();
        if (should_wake_worker) self.wakeLocked();
        self.condition.broadcast();
        while (self.waiter_count > 0) {
            self.condition.wait(&self.lock);
        }
        self.lock.unlock();

        self.scheduler.deinit();

        // The loop owns every live SideIO. It must be fully joined before
        // descriptor callbacks or storage are released.
        self.joinWorker();

        if (cleanup_in_deinit) {
            self.lock.lock();
            self.cleanupResourcesLocked();
            self.lock.unlock();
        }

        self.condition.deinit();
        self.lock.deinit();
    }

    pub fn start(self: *Looper) StartError!void {
        self.lock.lock();
        if (self.state != .idle) {
            self.lock.unlock();
            std.debug.assert(false);
            return error.AlreadyStarted;
        }
        self.state = .starting;
        self.lock.unlock();

        const fd_set = DescriptorSet.init(self.allocator) catch |err| {
            self.lock.lock();
            self.state = .idle;
            self.condition.broadcast();
            self.lock.unlock();
            return err;
        };

        self.lock.lock();
        self.fd_set = fd_set;
        c.pp_mux_set_on_readable(self.mux, onMuxReadable, &self.fd_set.?);
        c.pp_mux_set_on_writable(self.mux, onMuxWritable, &self.fd_set.?);
        self.lock.unlock();

        self.scheduler.start() catch |err| {
            self.lock.lock();
            self.fd_set.?.deinit();
            self.fd_set = null;
            self.state = .idle;
            self.condition.broadcast();
            self.lock.unlock();
            return err;
        };

        const worker = std.Thread.spawn(.{}, loopMain, .{self}) catch |err| {
            self.lock.lock();
            self.fd_set.?.deinit();
            self.fd_set = null;
            self.state = .idle;
            self.condition.broadcast();
            self.lock.unlock();
            return err;
        };

        log.writef(.info, "Start looper", .{});
        self.lock.lock();
        self.worker_thread = worker;
        self.state = .started;
        self.condition.broadcast();
        self.lock.unlock();
    }

    fn loopMain(self: *Looper) void {
        self.lock.lock();
        while (self.state == .starting) {
            self.condition.wait(&self.lock);
        }
        const loop_thread_id = std.Thread.getCurrentId();
        self.loop_thread_id = loop_thread_id;
        self.lock.unlock();

        defer self.clearLoopThread(loop_thread_id);
        while (self.loopOnce()) {}
        self.cleanupAfterLoop();
    }

    fn loopOnce(self: *Looper) bool {
        self.lock.lock();
        if (self.state == .deinitializing or self.state == .stopped) {
            self.lock.unlock();
            return false;
        }
        const fd_set = if (self.fd_set) |*value| value else {
            self.lock.unlock();
            return false;
        };
        self.lock.unlock();

        fd_set.resetReadable();
        var code: c_int = 0;
        if (c.pp_mux_wait(self.mux, &code) < 0) {
            log.writef(.err, "Looper: pp_mux_wait() failed (code={})", .{code});
            self.finish(.{ .wait = code });
            return false;
        }
        if (fd_set.allocation_failed) {
            self.finish(.{ .system = error.OutOfMemory });
            return false;
        }

        self.lock.lock();
        const released = self.state == .deinitializing;
        self.lock.unlock();
        if (released) {
            log.writef(.info, "Looper: released self", .{});
            return false;
        }

        const command_outcome = self.handleCommands(fd_set);
        self.lock.lock();
        const deinitializing_after_commands = self.state == .deinitializing;
        self.lock.unlock();
        if (deinitializing_after_commands) {
            return false;
        }
        if (command_outcome.failure) |failure| {
            if (sideFailure(failure)) |item| {
                self.detachImmediately(item.side, item.failure);
                return true;
            }
            self.finish(failure);
            return false;
        }
        if (!command_outcome.should_continue) {
            log.writef(.info, "Looper: stop requested", .{});
            self.finish(null);
            return false;
        }

        const process_outcome = self.process(fd_set);
        self.lock.lock();
        const deinitializing_after_process = self.state == .deinitializing;
        self.lock.unlock();
        if (deinitializing_after_process) {
            return false;
        }
        switch (process_outcome) {
            .ok => {},
            .side_failure => |item| self.detachImmediately(item.side, item.failure),
            .fatal => |failure| {
                self.finish(failure);
                return false;
            },
        }
        return true;
    }

    pub fn stop(self: *Looper) StopError!void {
        if (self.isReentrantLifecycleCall()) return error.ReentrantCall;

        var completion = Completion{};

        self.lock.lock();
        while (self.state == .starting) {
            self.condition.wait(&self.lock);
        }
        switch (self.state) {
            .idle => {
                self.lock.unlock();
                return;
            },
            .started => {},
            .starting => unreachable,
            .deinitializing => {
                self.lock.unlock();
                return error.Cancelled;
            },
            .stopping, .stopped => {
                self.lock.unlock();
                std.debug.assert(false);
                return error.InvalidState;
            },
        }
        const node = self.createCommandNode(.stop) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.state = .stopping;
        self.stop_completion = &completion;
        self.commands.append(node);
        self.waiter_count += 1;
        self.wakeLocked();
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const result = completion.result;
        self.lock.unlock();

        self.joinWorker();

        self.lock.lock();
        std.debug.assert(self.waiter_count > 0);
        self.waiter_count -= 1;
        self.condition.broadcast();
        self.lock.unlock();
        if (result) |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.TerminalFailure => error.TerminalFailure,
            else => unreachable,
        };
    }

    pub fn isOnQueue(self: *Looper) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const thread_id = self.loop_thread_id orelse return false;
        return thread_id == std.Thread.getCurrentId();
    }

    /// With no delay, runs inline on the looper thread or enqueues on it.
    /// Delayed work is always enqueued asynchronously after `delay_ms`.
    pub fn schedule(self: *Looper, delay_ms: ?u64, task: Task) ScheduleError!void {
        if (delay_ms == null and self.isOnQueue()) {
            task.call() catch |err| {
                log.writef(.err, "Scheduled task failed: {}", .{err});
                return error.TaskFailure;
            };
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();
        if (self.state != .started) {
            log.writef(.debug, "Ignoring schedule before start() or after finish", .{});
            return error.Cancelled;
        }
        if (delay_ms) |delay| {
            const node = try self.createCommandNode(.{ .perform = task });
            self.scheduler.schedule(&node.timer, delay, onScheduledCommand, self) catch unreachable;
            return;
        }
        const node = try self.createCommandNode(.{ .perform = task });
        self.commands.append(node);
        self.wakeLocked();
    }

    /// Performs a task synchronously with the worker. Runs inline
    /// if on the same queue to prevent deadlock.
    pub fn perform(
        self: *Looper,
        comptime Result: type,
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque) anyerror!Result,
    ) anyerror!Result {
        if (hasBorrowedCallback()) return error.ReentrantCall;
        if (self.isOnQueue()) return callback(context);

        const Holder = struct {
            context: ?*anyopaque,
            callback: *const fn (?*anyopaque) anyerror!Result,
            value: ?Result = null,
            failure: ?anyerror = null,

            fn run(raw_context: ?*anyopaque) anyerror!void {
                const holder: *@This() = @ptrCast(@alignCast(raw_context.?));
                holder.value = holder.callback(holder.context) catch |err| {
                    holder.failure = err;
                    return;
                };
            }
        };

        var holder = Holder{
            .context = context,
            .callback = callback,
        };
        var completion = Completion{};

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            log.writef(.debug, "Ignoring perform before start() or after finish", .{});
            return error.Cancelled;
        }
        const node = self.createCommandNode(.{ .schedule = .{
            .task = .{ .context = &holder, .callback = Holder.run },
            .completion = &completion,
        } }) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.commands.append(node);
        self.waiter_count += 1;
        self.wakeLocked();
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const command_result = completion.result;
        std.debug.assert(self.waiter_count > 0);
        self.waiter_count -= 1;
        self.condition.broadcast();
        self.lock.unlock();

        if (command_result) |err| return err;
        if (holder.failure) |err| return err;
        return holder.value.?;
    }

    pub fn performTask(self: *Looper, task: Task) anyerror!void {
        return self.perform(void, task.context, task.callback);
    }

    /// Ownership of `arguments.pair.io` transfers only after successful attach.
    pub fn attach(self: *Looper, arguments: AttachArguments) AttachError!void {
        if (self.isReentrantLifecycleCall()) return error.ReentrantCall;

        var completion = Completion{};

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            log.writef(.debug, "Ignoring attach before start() or after finish", .{});
            return error.Cancelled;
        }
        const node = self.createCommandNode(.{ .attach = .{
            .arguments = arguments,
            .completion = &completion,
        } }) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.commands.append(node);
        self.waiter_count += 1;
        self.wakeLocked();
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const result = completion.result;
        std.debug.assert(self.waiter_count > 0);
        self.waiter_count -= 1;
        self.condition.broadcast();
        self.lock.unlock();
        if (result) |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.OperationCancelled => error.OperationCancelled,
            else => error.MuxFailure,
        };
    }

    pub fn detach(self: *Looper, side: io.Side) DetachError!void {
        if (self.isReentrantLifecycleCall()) return error.ReentrantCall;

        var completion = Completion{};

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            log.writef(.debug, "Ignoring detach before start() or after finish", .{});
            return error.Cancelled;
        }
        const node = self.createCommandNode(.{ .detach = .{
            .side = side,
            .completion = &completion,
        } }) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.commands.append(node);
        self.waiter_count += 1;
        self.wakeLocked();
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const result = completion.result;
        std.debug.assert(self.waiter_count > 0);
        self.waiter_count -= 1;
        self.condition.broadcast();
        self.lock.unlock();
        if (result) |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Cancelled,
        };
    }

    pub fn isLinkAttached(self: *Looper) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.link != null;
    }

    pub fn isTunAttached(self: *Looper) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.tun != null;
    }

    pub fn terminalFailure(self: *Looper) ?Failure {
        self.lock.lock();
        defer self.lock.unlock();
        return self.terminal_failure;
    }

    pub fn resumeReading(self: *Looper, side: io.Side) ResumeReadingError!void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.state != .started) return error.Cancelled;
        const node = try self.createCommandNode(.{ .enable_read = .{
            .side = side,
            .id = null,
        } });
        self.commands.append(node);
        self.wakeLocked();
    }

    pub fn write(
        self: *Looper,
        packets: Packets,
        side: io.Side,
        out_of_band: bool,
    ) WriteError!void {
        if (out_of_band) return self.writeOutOfBand(packets, side);

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            return error.Cancelled;
        }
        const current = self.sideIO(side) orelse {
            self.lock.unlock();
            log.writef(.err, "Ignoring {} packets, not attached", .{side});
            return;
        };
        current.transform_drainer.enter();
        const id = current.id;
        const transform = current.transform_write;
        self.lock.unlock();

        const processed_result = if (transform) |callback|
            self.callTransform(callback, packets)
        else
            packets;

        self.lock.lock();
        defer self.lock.unlock();
        defer current.transform_drainer.leaveLocked();
        const processed = processed_result catch |err| {
            log.writef(.err, "{} write transform failed: {}", .{
                side,
                err,
            });
            return error.TransformFailure;
        };
        if (self.state != .started) return error.Cancelled;
        const attached = self.sideIO(side) orelse {
            log.writef(.debug, "Ignoring detached {} during processing", .{side});
            return;
        };
        if (attached.id != id) {
            log.writef(.debug, "Ignoring detached {} during processing", .{side});
            return;
        }

        const command = try self.createCommandNode(.{ .enable_write = .{
            .side = side,
            .id = id,
        } });
        errdefer self.allocator.destroy(command);

        try attached.write_queue.append(processed);
        self.commands.append(command);
        self.wakeLocked();
    }

    pub fn writeQueued(self: *Looper, packets: Packets, side: io.Side) WriteError!void {
        return self.write(packets, side, false);
    }

    fn writeOutOfBand(self: *Looper, packets: Packets, side: io.Side) WriteError!void {
        if (!self.isOnQueue()) {
            log.writef(.err, "OOB writes must run on the looper queue", .{});
            return;
        }

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            return error.Cancelled;
        }
        const side_io = self.sideIO(side) orelse {
            self.lock.unlock();
            log.writef(.err, "Ignoring {} packets, not attached", .{side});
            return;
        };
        const transform = side_io.transform_write;
        self.lock.unlock();

        const processed = if (transform) |callback|
            self.callTransform(callback, packets) catch |err| {
                log.writef(.err, "{} write transform failed: {}", .{
                    side,
                    err,
                });
                return error.TransformFailure;
            }
        else
            packets;
        for (processed) |packet| {
            const written = side_io.native_io.write(packet, 0) catch |err| {
                log.writef(.err, "{} write failed: {}", .{ side, err });
                return err;
            };
            if (written != packet.len) {
                log.writef(.err, "Incomplete {} write ({}/{})", .{
                    side,
                    written,
                    packet.len,
                });
                return error.WriteIncomplete;
            }
        }
    }

    fn onMuxReadable(context: ?*anyopaque, fd: io.FileDescriptor) callconv(.c) void {
        const fd_set: *DescriptorSet = @ptrCast(@alignCast(context.?));
        fd_set.insertReadable(fd);
    }

    fn onMuxWritable(context: ?*anyopaque, fd: io.FileDescriptor) callconv(.c) void {
        const fd_set: *DescriptorSet = @ptrCast(@alignCast(context.?));
        fd_set.insertWritable(fd);
    }

    fn handleCommands(self: *Looper, fd_set: *DescriptorSet) CommandOutcome {
        self.lock.lock();
        var pending = self.commands.takeReady();

        var outcome = CommandOutcome{};
        while (pending) |node| {
            const next = node.next;
            switch (node.command) {
                .attach => |command| self.handleAttachLocked(
                    command.arguments,
                    command.completion,
                ),
                .detach => |command| self.handleDetachLocked(
                    command.side,
                    command.completion,
                ),
                .enable_read => |identity| {
                    if (!self.isOutdatedLocked(identity)) {
                        self.handleEnableReadLocked(identity.side) catch |err| {
                            outcome.failure = .{ .system = err };
                        };
                    }
                },
                .enable_write => |identity| {
                    if (!self.isOutdatedLocked(identity)) {
                        self.handleEnableWriteLocked(identity.side, fd_set) catch |err| {
                            outcome.failure = .{ .system = err };
                        };
                    }
                },
                .schedule => |command| {
                    self.lock.unlock();
                    command.task.call() catch unreachable;
                    self.lock.lock();
                    completeNow(command.completion, null);
                    self.condition.broadcast();
                    // Give the synchronous caller a chance to return before
                    // processing the rest of this detached command batch.
                    self.lock.unlock();
                    self.lock.lock();
                },
                .perform => |task| {
                    self.lock.unlock();
                    task.call() catch |err| {
                        self.lock.lock();
                        outcome.failure = .{ .user = err };
                        self.lock.unlock();
                    };
                    self.lock.lock();
                },
                .stop => {
                    log.writef(.info, "Stop looper", .{});
                    outcome.should_continue = false;
                },
            }
            self.allocator.destroy(node);
            pending = next;
            if (outcome.failure != null or !outcome.should_continue) {
                self.cancelPendingLocked(pending);
                pending = null;
            }
        }
        self.releaseCompletionsLocked();
        self.condition.broadcast();
        self.lock.unlock();
        return outcome;
    }

    fn handleAttachLocked(
        self: *Looper,
        arguments: AttachArguments,
        completion: *Completion,
    ) void {
        if (self.state != .started) {
            self.queueCompletionLocked(completion, error.Cancelled);
            return;
        }

        const side = std.meta.activeTag(arguments.pair);
        if (self.sideIO(side) != null) {
            self.queueCompletionLocked(completion, error.OperationCancelled);
            return;
        }
        const descriptor = switch (arguments.pair) {
            .link => |value| value,
            .tun => |value| value,
        };
        if (!c.pp_mux_add(self.mux, descriptor.fd)) {
            log.writef(.err, "Unable to attach {} (fd={any})", .{ side, descriptor.fd });
            self.queueCompletionLocked(completion, error.MuxFailure);
            return;
        }
        log.writef(.info, "Attach {} (fd={any})", .{ side, descriptor.fd });

        const id = self.next_side_id;
        self.next_side_id +%= 1;
        const side_io = SideIO.create(
            self.allocator,
            id,
            side,
            descriptor,
            self.readBufferSize(side),
            arguments,
        ) catch |err| {
            _ = c.pp_mux_delete(self.mux, descriptor.fd);
            self.queueCompletionLocked(completion, err);
            return;
        };
        side_io.syncEventMask() catch {
            log.writef(.err, "Unable to retain {}", .{side});
            _ = c.pp_mux_delete(self.mux, descriptor.fd);
            side_io.destroyStorage(self.allocator);
            self.queueCompletionLocked(completion, error.MuxFailure);
            return;
        };

        self.setSideIO(side, side_io);
        self.queueCompletionLocked(completion, null);
    }

    fn handleDetachLocked(
        self: *Looper,
        side: io.Side,
        completion: *Completion,
    ) void {
        if (self.takeSideIOLocked(side)) |side_io| {
            self.destroyDetachedSideIOLocked(side_io);
        }
        self.queueCompletionLocked(completion, null);
    }

    fn handleEnableReadLocked(self: *Looper, side: io.Side) io.Error!void {
        if (self.sideIO(side)) |side_io| {
            try side_io.setRead(self.mux, true);
        } else {
            log.writef(.err, "Ignoring enableRead({}), not attached", .{side});
        }
    }

    fn handleEnableWriteLocked(
        self: *Looper,
        side: io.Side,
        fd_set: *DescriptorSet,
    ) io.Error!void {
        if (self.sideIO(side)) |side_io| {
            try side_io.setWrite(self.mux, true);
            fd_set.insertWritable(side_io.fd);
        } else {
            log.writef(.err, "Ignoring enableWrite({}), not attached", .{side});
        }
    }

    fn process(self: *Looper, fd_set: *DescriptorSet) ProcessOutcome {
        if (self.link) |link| {
            if (fd_set.isReadable(link.fd) or fd_set.isWritable(link.fd)) {
                link.resetEvents() catch |err| return .{ .fatal = .{ .system = err } };
            }
        }
        if (self.tun) |tun| {
            if (fd_set.isReadable(tun.fd) or fd_set.isWritable(tun.fd)) {
                tun.resetEvents() catch |err| return .{ .fatal = .{ .system = err } };
            }
        }

        if (self.link) |link| {
            if (fd_set.isWritable(link.fd)) {
                const outcome = self.processWrite(link, self.tun, fd_set);
                if (outcome != .ok) return outcome;
            }
        }
        if (self.tun) |tun| {
            if (fd_set.isWritable(tun.fd)) {
                const outcome = self.processWrite(tun, self.link, fd_set);
                if (outcome != .ok) return outcome;
            }
        }
        if (self.tun) |tun| {
            if (fd_set.isReadable(tun.fd)) {
                const outcome = self.processRead(tun);
                if (outcome != .ok) return outcome;
            }
        }
        if (self.link) |link| {
            if (fd_set.isReadable(link.fd)) return self.processRead(link);
        }
        return .ok;
    }

    fn processWrite(
        self: *Looper,
        side_io: *SideIO,
        opposite: ?*SideIO,
        fd_set: *DescriptorSet,
    ) ProcessOutcome {
        var watch_writes = false;
        while (self.pendingWrite(side_io)) |pending| {
            const written = side_io.native_io.write(pending.data, pending.offset) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        watch_writes = true;
                        break;
                    },
                    error.Backpressure => {
                        if (opposite) |other| {
                            if (self.suspendReadAndScheduleRetry(other, fd_set)) |failure| {
                                return .{ .fatal = failure };
                            }
                        }
                        if (self.scheduleWriteRetry(side_io)) |failure| {
                            return .{ .fatal = failure };
                        }
                        watch_writes = false;
                        break;
                    },
                    else => return .{ .side_failure = .{
                        .side = side_io.side,
                        .failure = self.ioFailure(side_io, err),
                    } },
                }
            };
            self.lock.lock();
            const did_complete = side_io.write_queue.advance(written);
            self.lock.unlock();
            watch_writes = !did_complete;
        }

        side_io.setWrite(self.mux, watch_writes) catch |err| {
            return .{ .fatal = .{ .system = err } };
        };
        if (!watch_writes) fd_set.removeWritable(side_io.fd);
        return .ok;
    }

    fn processRead(self: *Looper, side_io: *SideIO) ProcessOutcome {
        var inbox: std.ArrayList(Packet) = .empty;
        defer {
            for (inbox.items) |packet| self.allocator.free(@constCast(packet));
            inbox.deinit(self.allocator);
        }

        var read_count: usize = 0;
        var read_size: usize = 0;
        while (read_count < self.options.max_read_count and read_size < self.options.max_read_size) {
            const maybe_count = side_io.native_io.read(side_io.read_buf) catch |err| {
                if (err == error.WouldBlock) break;
                return .{ .side_failure = .{
                    .side = side_io.side,
                    .failure = self.ioFailure(side_io, err),
                } };
            };
            if (maybe_count) |count| {
                const packet = self.allocator.dupe(u8, side_io.read_buf[0..count]) catch |err| {
                    return .{ .fatal = .{ .system = err } };
                };
                inbox.append(self.allocator, packet) catch |err| {
                    self.allocator.free(packet);
                    return .{ .fatal = .{ .system = err } };
                };
                read_size += count;
            }
            read_count += 1;
        }

        if (inbox.items.len > 0) {
            const action = if (side_io.on_read) |callback|
                callback.call(inbox.items) catch |err| {
                    return .{ .side_failure = .{
                        .side = side_io.side,
                        .failure = .{ .user = err },
                    } };
                }
            else
                ReadAction.keep;
            if (action == .pause) {
                side_io.setRead(self.mux, false) catch |err| {
                    return .{ .fatal = .{ .system = err } };
                };
            }
        }
        return .ok;
    }

    fn suspendReadAndScheduleRetry(
        self: *Looper,
        side_io: *SideIO,
        fd_set: *DescriptorSet,
    ) ?Failure {
        side_io.setRead(self.mux, false) catch |err| return .{ .system = err };
        fd_set.removeReadable(side_io.fd);

        self.lock.lock();
        defer self.lock.unlock();
        const index = sideIndex(side_io.side);
        if (self.state != .started or self.read_retries[index]) return null;
        const node = self.createCommandNode(.{ .enable_read = .{
            .side = side_io.side,
            .id = side_io.id,
        } }) catch |err| return .{ .system = err };
        self.read_retries[index] = true;
        self.scheduler.schedule(
            &node.timer,
            no_buf_retry_delay_ms,
            onScheduledCommand,
            self,
        ) catch unreachable;
        return null;
    }

    fn scheduleWriteRetry(self: *Looper, side_io: *SideIO) ?Failure {
        self.lock.lock();
        defer self.lock.unlock();
        const index = sideIndex(side_io.side);
        if (self.state != .started or self.write_retries[index]) return null;
        const node = self.createCommandNode(.{ .enable_write = .{
            .side = side_io.side,
            .id = side_io.id,
        } }) catch |err| return .{ .system = err };
        self.write_retries[index] = true;
        self.scheduler.schedule(
            &node.timer,
            no_buf_retry_delay_ms,
            onScheduledCommand,
            self,
        ) catch unreachable;
        return null;
    }

    fn detachImmediately(self: *Looper, side: io.Side, failure: Failure) void {
        self.lock.lock();
        const side_io = self.takeSideIOLocked(side) orelse {
            self.lock.unlock();
            return;
        };
        side_io.transform_drainer.drain(&self.lock);
        const on_failure = side_io.on_failure;
        self.lock.unlock();

        // User code must never execute while holding the looper mutex.
        if (on_failure) |callback| callback.call(failure);

        self.lock.lock();
        self.destroyDetachedSideIOLocked(side_io);
        self.lock.unlock();
    }

    fn finish(self: *Looper, failure: ?Failure) void {
        self.lock.lock();
        switch (self.state) {
            .deinitializing => {
                self.lock.unlock();
                return;
            },
            .stopped => {
                self.lock.unlock();
                std.debug.assert(false);
                return;
            },
            else => {},
        }
        self.state = .stopped;
        self.terminal_failure = failure;
        self.cancelPendingLocked(self.commands.takeReady());
        self.read_retries = .{ false, false };
        self.write_retries = .{ false, false };
        if (self.stop_completion) |completion| {
            completeNow(completion, if (failure != null) error.TerminalFailure else null);
            self.stop_completion = null;
        }
        self.releaseCompletionsLocked();
        self.condition.broadcast();
        self.lock.unlock();

        self.scheduler.cancel();

        if (failure) |reason| {
            log.writef(.err, "Finish looper with error: {}", .{reason});
        } else {
            log.writef(.info, "Finish looper", .{});
        }
        self.options.on_finish.call(failure);
    }

    fn cleanupAfterLoop(self: *Looper) void {
        self.lock.lock();
        self.cleanupResourcesLocked();
        self.condition.broadcast();
        self.lock.unlock();
    }

    fn joinWorker(self: *Looper) void {
        self.lock.lock();
        const worker = self.worker_thread;
        self.worker_thread = null;
        self.lock.unlock();
        if (worker) |thread| thread.join();
    }

    fn clearLoopThread(self: *Looper, thread_id: std.Thread.Id) void {
        self.lock.lock();
        if (self.loop_thread_id == thread_id) self.loop_thread_id = null;
        self.condition.broadcast();
        self.lock.unlock();
    }

    fn wakeLocked(self: *Looper) void {
        _ = c.pp_mux_wake(self.mux);
    }

    fn isReentrantLifecycleCall(self: *Looper) bool {
        return hasBorrowedCallback() or self.isOnQueue();
    }

    fn hasBorrowedCallback() bool {
        return borrowed_callback_depth > 0;
    }

    fn callTransform(
        self: *Looper,
        transform: TransformWrite,
        packets: Packets,
    ) anyerror!Packets {
        _ = self;
        borrowed_callback_depth += 1;
        defer borrowed_callback_depth -= 1;
        return transform.call(packets);
    }

    fn callNativeCleanup(self: *Looper, side_io: *SideIO) void {
        _ = self;
        borrowed_callback_depth += 1;
        defer borrowed_callback_depth -= 1;
        side_io.cleanupNative();
    }

    /// Removes a side from publication before waiting for borrowed transform
    /// callbacks. Caller must hold `lock`.
    fn takeSideIOLocked(self: *Looper, side: io.Side) ?*SideIO {
        const side_io = self.sideIO(side) orelse return null;
        self.setSideIO(side, null);
        self.read_retries[sideIndex(side)] = false;
        self.write_retries[sideIndex(side)] = false;
        if (self.fd_set) |*fd_set| {
            fd_set.removeReadable(side_io.fd);
            fd_set.removeWritable(side_io.fd);
        }
        return side_io;
    }

    /// Caller must hold `lock`, and `side_io` must already be unpublished.
    /// Returns with `lock` held, but invokes native cleanup without it.
    fn destroyDetachedSideIOLocked(self: *Looper, side_io: *SideIO) void {
        side_io.transform_drainer.drain(&self.lock);
        const should_cleanup = side_io.detachFromMux(self.mux);
        self.lock.unlock();
        if (should_cleanup) self.callNativeCleanup(side_io);
        side_io.destroyStorage(self.allocator);
        self.lock.lock();
    }

    /// Destroys every mux-owned resource. Caller must hold `lock` and the loop
    /// must either be the caller or have been joined.
    fn cleanupResourcesLocked(self: *Looper) void {
        if (self.link != null) {
            const side_io = self.takeSideIOLocked(.link).?;
            self.destroyDetachedSideIOLocked(side_io);
        }
        if (self.tun != null) {
            const side_io = self.takeSideIOLocked(.tun).?;
            self.destroyDetachedSideIOLocked(side_io);
        }
        if (self.fd_set) |*fd_set| {
            fd_set.deinit();
            self.fd_set = null;
        }
        c.pp_mux_free(self.mux);
    }

    fn sideIO(self: *Looper, side: io.Side) ?*SideIO {
        return switch (side) {
            .link => self.link,
            .tun => self.tun,
        };
    }

    fn setSideIO(self: *Looper, side: io.Side, side_io: ?*SideIO) void {
        switch (side) {
            .link => self.link = side_io,
            .tun => self.tun = side_io,
        }
    }

    fn readBufferSize(self: Looper, side: io.Side) usize {
        return switch (side) {
            .link => self.options.link_buf_size,
            .tun => self.options.tun_buf_size,
        };
    }

    fn isOutdatedLocked(self: *Looper, identity: SideIdentity) bool {
        const id = identity.id orelse return false;
        const side_io = self.sideIO(identity.side) orelse return true;
        return id != side_io.id;
    }

    fn ioFailure(self: *Looper, side_io: *SideIO, cause: io.Error) Failure {
        _ = self;
        return .{ .io = .{
            .side = side_io.side,
            .cause = cause,
            .code = if (cause == error.LibcFailure)
                side_io.native_io.lastErrorCode()
            else
                null,
        } };
    }

    fn pendingWrite(self: *Looper, side_io: *SideIO) ?queue_mod.PendingWrite {
        self.lock.lock();
        defer self.lock.unlock();
        return side_io.write_queue.pending();
    }

    fn createCommandNode(self: *Looper, command: Command) std.mem.Allocator.Error!*CommandNode {
        const node = try self.allocator.create(CommandNode);
        node.* = .{ .command = command };
        return node;
    }

    fn onScheduledCommand(
        scheduled: *core.RunAfter.Scheduled,
        outcome: core.RunAfter.Scheduled.Outcome,
    ) void {
        const node: *CommandNode = @fieldParentPtr("timer", scheduled);
        const self: *Looper = @ptrCast(@alignCast(scheduled.context.?));
        self.lock.lock();
        defer self.lock.unlock();

        self.clearRetryForCommand(node.command);
        if (outcome == .elapsed and self.state == .started) {
            self.commands.append(node);
            self.wakeLocked();
        } else {
            self.allocator.destroy(node);
        }
    }

    fn clearRetryForCommand(self: *Looper, command: Command) void {
        switch (command) {
            .enable_read => |identity| if (identity.id != null) {
                self.read_retries[sideIndex(identity.side)] = false;
            },
            .enable_write => |identity| if (identity.id != null) {
                self.write_retries[sideIndex(identity.side)] = false;
            },
            else => {},
        }
    }

    fn cancelPendingLocked(self: *Looper, pending_head: ?*CommandNode) void {
        var pending = pending_head;
        while (pending) |node| {
            const next = node.next;
            self.clearRetryForCommand(node.command);
            switch (node.command) {
                .attach => |command| self.queueCompletionLocked(command.completion, error.Cancelled),
                .detach => |command| self.queueCompletionLocked(command.completion, error.Cancelled),
                .schedule => |command| self.queueCompletionLocked(command.completion, error.Cancelled),
                else => {},
            }
            self.allocator.destroy(node);
            pending = next;
        }
    }

    fn queueCompletionLocked(
        self: *Looper,
        completion: *Completion,
        result: ?CompletionError,
    ) void {
        self.completions.append(completion, result);
    }

    fn releaseCompletionsLocked(self: *Looper) void {
        self.completions.releaseAll();
    }

    fn completeNow(completion: *Completion, result: ?CompletionError) void {
        completion.result = result;
        completion.done = true;
    }

    fn sideIndex(side: io.Side) usize {
        return switch (side) {
            .link => 0,
            .tun => 1,
        };
    }

    const TaggedSideFailure = struct {
        side: io.Side,
        failure: Failure,
    };

    fn sideFailure(failure: Failure) ?TaggedSideFailure {
        return switch (failure) {
            .io => |item| .{ .side = item.side, .failure = failure },
            else => null,
        };
    }

    const SideIO = struct {
        // Identity and native I/O.
        id: u64,
        side: io.Side,
        fd: io.FileDescriptor,
        native_io: io.IOInterface,

        // User callbacks.
        transform_write: ?TransformWrite,
        on_read: ?OnRead,
        on_failure: ?OnFailure,

        // Buffered packet state.
        read_buf: []u8,
        write_queue: WriteQueue,

        // Mux event and cleanup state.
        is_reading: bool = true,
        is_writing: bool = false,
        did_cleanup: bool = false,

        // In-flight transform synchronization.
        transform_drainer: core.Drainer = .{},

        fn create(
            allocator: std.mem.Allocator,
            id: u64,
            side: io.Side,
            descriptor: Descriptor,
            read_buf_size: usize,
            arguments: AttachArguments,
        ) std.mem.Allocator.Error!*SideIO {
            const self = try allocator.create(SideIO);
            errdefer allocator.destroy(self);
            const read_buf = try allocator.alloc(u8, read_buf_size);
            self.* = .{
                .id = id,
                .side = side,
                .fd = descriptor.fd,
                .native_io = descriptor.io,
                .transform_write = arguments.transform_write,
                .on_read = arguments.on_read,
                .on_failure = arguments.on_failure,
                .read_buf = read_buf,
                .write_queue = WriteQueue.init(allocator),
            };
            return self;
        }

        fn destroyStorage(self: *SideIO, allocator: std.mem.Allocator) void {
            self.write_queue.deinit();
            allocator.free(self.read_buf);
            self.transform_drainer.deinit();
            allocator.destroy(self);
        }

        fn resetEvents(self: *SideIO) io.Error!void {
            return self.native_io.resetEvents();
        }

        fn setRead(self: *SideIO, mux: c.pp_mux, enabled: bool) io.Error!void {
            _ = c.pp_mux_set_read(mux, self.fd, enabled);
            self.is_reading = enabled;
            try self.syncEventMask();
        }

        fn setWrite(self: *SideIO, mux: c.pp_mux, enabled: bool) io.Error!void {
            _ = c.pp_mux_set_write(mux, self.fd, enabled);
            self.is_writing = enabled;
            try self.syncEventMask();
        }

        fn syncEventMask(self: *SideIO) io.Error!void {
            return self.native_io.setEventMask(self.is_reading, self.is_writing);
        }

        fn detachFromMux(self: *SideIO, mux: c.pp_mux) bool {
            if (self.did_cleanup) return false;
            self.did_cleanup = true;
            _ = c.pp_mux_delete(mux, self.fd);
            return true;
        }

        fn cleanupNative(self: *SideIO) void {
            self.native_io.cleanup();
        }
    };

    const DescriptorSet = struct {
        allocator: std.mem.Allocator,

        readable: std.ArrayList(io.FileDescriptor) = .empty,
        writable: std.ArrayList(io.FileDescriptor) = .empty,

        allocation_failed: bool = false,

        fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!DescriptorSet {
            var self = DescriptorSet{ .allocator = allocator };
            errdefer self.deinit();
            try self.readable.ensureTotalCapacity(allocator, number_of_descriptors);
            try self.writable.ensureTotalCapacity(allocator, number_of_descriptors);
            return self;
        }

        fn deinit(self: *DescriptorSet) void {
            self.readable.deinit(self.allocator);
            self.writable.deinit(self.allocator);
        }

        fn resetReadable(self: *DescriptorSet) void {
            self.readable.clearRetainingCapacity();
        }

        fn insertReadable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            self.insert(&self.readable, fd) catch {
                self.allocation_failed = true;
            };
        }

        fn insertWritable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            self.insert(&self.writable, fd) catch {
                self.allocation_failed = true;
            };
        }

        fn insert(
            self: *DescriptorSet,
            list: *std.ArrayList(io.FileDescriptor),
            fd: io.FileDescriptor,
        ) std.mem.Allocator.Error!void {
            if (contains(list.items, fd)) return;
            try list.append(self.allocator, fd);
        }

        fn removeReadable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            remove(&self.readable, fd);
        }

        fn removeWritable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            remove(&self.writable, fd);
        }

        fn isReadable(self: DescriptorSet, fd: io.FileDescriptor) bool {
            return contains(self.readable.items, fd);
        }

        fn isWritable(self: DescriptorSet, fd: io.FileDescriptor) bool {
            return contains(self.writable.items, fd);
        }

        fn contains(list: []const io.FileDescriptor, fd: io.FileDescriptor) bool {
            for (list) |item| {
                if (item == fd) return true;
            }
            return false;
        }

        fn remove(list: *std.ArrayList(io.FileDescriptor), fd: io.FileDescriptor) void {
            for (list.items, 0..) |item, index| {
                if (item == fd) {
                    _ = list.orderedRemove(index);
                    return;
                }
            }
        }
    };
};
