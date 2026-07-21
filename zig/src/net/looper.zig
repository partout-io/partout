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
const c = io.c;
const log = core.logging;

pub const Looper = struct {
    pub const ReadAction = enum {
        keep,
        pause,
    };

    pub const Packet = []const u8;
    pub const Packets = []const Packet;

    pub const TransformWrite = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque, Packets) anyerror!Packets,

        fn call(self: TransformWrite, packets: Packets) anyerror!Packets {
            return self.callback(self.context, packets);
        }
    };

    pub const OnRead = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque, Packets) anyerror!ReadAction,

        fn call(self: OnRead, packets: Packets) anyerror!ReadAction {
            return self.callback(self.context, packets);
        }
    };

    pub const Failure = union(enum) {
        mux: ?io.Side,
        wait: c_int,
        io: struct {
            side: io.Side,
            cause: io.Error,
            code: ?c_int,
        },
        user: anyerror,
        system: anyerror,

        pub fn err(self: Failure) anyerror {
            return switch (self) {
                .mux => error.MuxFailure,
                .wait => error.WaitFailure,
                .io => |failure| failure.cause,
                .user => |reason| reason,
                .system => |reason| reason,
            };
        }
    };

    pub const OnFailure = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque, Failure) void,

        fn call(self: OnFailure, failure: Failure) void {
            self.callback(self.context, failure);
        }
    };

    pub const OnFinish = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque, ?Failure) void,

        fn call(self: OnFinish, failure: ?Failure) void {
            self.callback(self.context, failure);
        }
    };

    pub const Task = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque) anyerror!void,

        fn call(self: Task) anyerror!void {
            return self.callback(self.context);
        }
    };

    pub const Descriptor = struct {
        fd: io.FileDescriptor,
        io: io.IOInterface,
    };

    pub const DescriptorPair = union(io.Side) {
        link: Descriptor,
        tun: Descriptor,
    };

    pub const AttachArguments = struct {
        pair: DescriptorPair,
        transform_write: ?TransformWrite = null,
        on_read: ?OnRead = null,
        on_failure: ?OnFailure = null,
    };

    pub const Options = struct {
        link_buf_size: usize = 64 * 1024,
        tun_buf_size: usize = 16 * 1024,
        max_read_size: usize = 256 * 1024,
        max_read_count: usize = 128,
        on_finish: OnFinish,
    };

    pub const InitError = std.mem.Allocator.Error || error{MuxFailure};
    pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError || error{AlreadyStarted};
    pub const AttachError = std.mem.Allocator.Error || error{
        Cancelled,
        MuxFailure,
        OperationCancelled,
        ReentrantCall,
    };
    pub const DetachError = std.mem.Allocator.Error || error{
        Cancelled,
        ReentrantCall,
    };
    pub const ResumeReadingError = std.mem.Allocator.Error || error{Cancelled};

    allocator: std.mem.Allocator,
    mux: c.pp_mux,
    link_buf_size: usize,
    tun_buf_size: usize,
    max_read_size: usize,
    max_read_count: usize,
    on_finish: OnFinish,

    lock: core.Mutex = .{},
    condition: core.Condition = .{},
    state: State = .idle,
    command_head: ?*CommandNode = null,
    command_tail: ?*CommandNode = null,
    completion_head: ?*Completion = null,
    completion_tail: ?*Completion = null,
    waiter_count: usize = 0,
    scheduled_head: ?*CommandNode = null,
    read_retries: [2]bool = .{ false, false },
    write_retries: [2]bool = .{ false, false },
    link: ?*SideIO = null,
    tun: ?*SideIO = null,
    stop_completion: ?*Completion = null,
    terminal_failure: ?Failure = null,
    next_side_id: u64 = 1,
    worker_thread: ?std.Thread = null,
    loop_thread_id: ?std.Thread.Id = null,
    fd_set: ?DescriptorSet = null,
    deinitializing: bool = false,
    mux_freed: bool = false,

    threadlocal var borrowed_callback_depth: usize = 0;

    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        const mux = c.pp_mux_create(number_of_descriptors) orelse {
            log.writef(.err, "Unable to create mux", .{});
            return error.MuxFailure;
        };
        return .{
            .allocator = allocator,
            .mux = mux,
            .link_buf_size = options.link_buf_size,
            .tun_buf_size = options.tun_buf_size,
            .max_read_size = @max(
                options.max_read_size,
                @max(options.link_buf_size, options.tun_buf_size),
            ),
            .max_read_count = options.max_read_count,
            .on_finish = options.on_finish,
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
        self.deinitializing = true;
        if (self.state == .idle or self.state == .started) {
            self.state = .stopping;
        }

        const pending = self.command_head;
        self.command_head = null;
        self.command_tail = null;
        self.cancelPendingLocked(pending);
        self.destroyCommandList(self.scheduled_head);
        self.scheduled_head = null;
        self.read_retries = .{ false, false };
        self.write_retries = .{ false, false };
        if (self.stop_completion) |completion| {
            completeNow(completion, error.Cancelled);
            self.stop_completion = null;
        }
        self.releaseCompletionsLocked();
        self.wakeLocked();
        self.condition.broadcast();
        while (self.waiter_count > 0) {
            self.condition.wait(&self.lock);
        }
        self.lock.unlock();

        // The loop owns every live SideIO. It must be fully joined before
        // descriptor callbacks or storage are released.
        self.joinWorker();

        self.lock.lock();
        self.cleanupResourcesLocked();
        self.lock.unlock();

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
        if (self.deinitializing or self.state == .stopped or self.mux_freed) {
            self.lock.unlock();
            return false;
        }
        const now_ns = core.concurrency.monotonicNs();
        self.promoteDueScheduledLocked(now_ns);
        const timeout_ms = self.waitTimeoutMsLocked(now_ns);
        const fd_set = if (self.fd_set) |*value| value else {
            self.lock.unlock();
            return false;
        };
        self.lock.unlock();

        fd_set.resetReadable();
        var code: c_int = 0;
        if (c.pp_mux_wait_timeout(self.mux, &code, timeout_ms) < 0) {
            log.writef(.err, "Looper: pp_mux_wait_timeout() failed (code={})", .{code});
            self.finish(.{ .wait = code });
            return false;
        }
        if (fd_set.allocation_failed) {
            self.finish(.{ .system = error.OutOfMemory });
            return false;
        }

        self.lock.lock();
        self.promoteDueScheduledLocked(core.concurrency.monotonicNs());
        const released = self.deinitializing;
        self.lock.unlock();
        if (released) {
            log.writef(.info, "Looper: released self", .{});
            return false;
        }

        const command_outcome = self.handleCommands(fd_set);
        self.lock.lock();
        const deinitializing_after_commands = self.deinitializing;
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
        const deinitializing_after_process = self.deinitializing;
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

    pub fn stop(self: *Looper) anyerror!void {
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
        self.appendCommandNode(node);
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
        if (result) |err| return err;
    }

    pub fn isOnQueue(self: *Looper) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const thread_id = self.loop_thread_id orelse return false;
        return thread_id == std.Thread.getCurrentId();
    }

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
        const node = self.createCommandNode(.{ .perform = .{
            .task = .{ .context = &holder, .callback = Holder.run },
            .completion = &completion,
        } }) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.appendCommandNode(node);
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

    /// With no delay, runs inline on the looper thread or enqueues on it.
    /// Delayed work is always enqueued asynchronously after `delay_ms`.
    pub fn schedule(self: *Looper, delay_ms: ?u64, task: Task) anyerror!void {
        if (delay_ms == null and self.isOnQueue()) return task.call();

        self.lock.lock();
        defer self.lock.unlock();
        if (self.state != .started or self.mux_freed) {
            log.writef(.debug, "Ignoring schedule before start() or after finish", .{});
            return error.Cancelled;
        }
        if (delay_ms) |delay| {
            const node = try self.createCommandNode(.{ .custom = task });
            node.deadline_ns = deadlineAfter(delay);
            if (self.insertScheduledNode(node)) self.wakeLocked();
            return;
        }
        const node = try self.createCommandNode(.{ .custom = task });
        self.appendCommandNode(node);
        self.wakeLocked();
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
        self.appendCommandNode(node);
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
        self.appendCommandNode(node);
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
        if (self.state != .started or self.mux_freed) return error.Cancelled;
        const node = try self.createCommandNode(.{ .enable_read = .{
            .side = side,
            .id = null,
        } });
        self.appendCommandNode(node);
        self.wakeLocked();
    }

    pub fn write(
        self: *Looper,
        packets: Packets,
        side: io.Side,
        out_of_band: bool,
    ) anyerror!void {
        if (out_of_band) return self.writeOutOfBand(packets, side);

        self.lock.lock();
        if (self.state != .started or self.mux_freed) {
            self.lock.unlock();
            return error.Cancelled;
        }
        const current = self.sideIO(side) orelse {
            self.lock.unlock();
            log.writef(.err, "Ignoring {s} packets, not attached", .{@tagName(side)});
            return;
        };
        current.transform_drainer.enter();
        const id = current.id;
        const transform = current.transform_write;
        self.lock.unlock();

        const processed_result: anyerror!Packets = if (transform) |callback|
            self.callTransform(callback, packets)
        else
            packets;

        self.lock.lock();
        defer self.lock.unlock();
        defer current.transform_drainer.leaveLocked();
        const processed = try processed_result;
        if (self.state != .started or self.mux_freed) return error.Cancelled;
        const attached = self.sideIO(side) orelse {
            log.writef(.debug, "Ignoring detached {s} during processing", .{@tagName(side)});
            return;
        };
        if (attached.id != id) {
            log.writef(.debug, "Ignoring detached {s} during processing", .{@tagName(side)});
            return;
        }

        const command = try self.createCommandNode(.{ .enable_write = .{
            .side = side,
            .id = id,
        } });
        errdefer self.allocator.destroy(command);

        var new_head: ?*WriteNode = null;
        var new_tail: ?*WriteNode = null;
        errdefer self.destroyWriteList(new_head);
        for (processed) |packet| {
            const copy = try self.allocator.dupe(u8, packet);
            errdefer self.allocator.free(copy);
            const node = try self.allocator.create(WriteNode);
            node.* = .{ .data = copy };
            if (new_tail) |tail| {
                tail.next = node;
            } else {
                new_head = node;
            }
            new_tail = node;
        }
        if (new_head) |head| {
            if (attached.write_tail) |tail| {
                tail.next = head;
            } else {
                attached.write_head = head;
            }
            attached.write_tail = new_tail;
        }
        self.appendCommandNode(command);
        self.wakeLocked();
    }

    pub fn writeQueued(self: *Looper, packets: Packets, side: io.Side) anyerror!void {
        return self.write(packets, side, false);
    }

    const number_of_descriptors = 2;
    const no_buf_retry_delay_ms = 10;

    const State = enum {
        idle,
        starting,
        started,
        stopping,
        stopped,
    };

    const SideIdentity = struct {
        side: io.Side,
        id: ?u64,
    };

    const Completion = struct {
        done: bool = false,
        result: ?anyerror = null,
        next: ?*Completion = null,
    };

    const Command = union(enum) {
        attach: struct {
            arguments: AttachArguments,
            completion: *Completion,
        },
        detach: struct {
            side: io.Side,
            completion: *Completion,
        },
        enable_read: SideIdentity,
        enable_write: SideIdentity,
        perform: struct {
            task: Task,
            completion: *Completion,
        },
        custom: Task,
        stop,
    };

    const CommandNode = struct {
        command: Command,
        next: ?*CommandNode = null,
        deadline_ns: u64 = 0,
    };

    const CommandOutcome = struct {
        should_continue: bool = true,
        failure: ?Failure = null,
    };

    const ProcessOutcome = union(enum) {
        ok,
        side_failure: struct {
            side: io.Side,
            failure: Failure,
        },
        fatal: Failure,
    };

    const WriteNode = struct {
        data: []u8,
        next: ?*WriteNode = null,
    };

    const SideIO = struct {
        id: u64,
        side: io.Side,
        fd: io.FileDescriptor,
        native_io: io.IOInterface,
        transform_write: ?TransformWrite,
        on_read: ?OnRead,
        on_failure: ?OnFailure,
        read_buf: []u8,
        write_head: ?*WriteNode = null,
        write_tail: ?*WriteNode = null,
        write_offset: usize = 0,
        is_reading: bool = true,
        is_writing: bool = false,
        did_cleanup: bool = false,
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
            };
            return self;
        }

        fn destroyStorage(self: *SideIO, allocator: std.mem.Allocator) void {
            var current = self.write_head;
            while (current) |node| {
                const next = node.next;
                allocator.free(node.data);
                allocator.destroy(node);
                current = next;
            }
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

    fn writeOutOfBand(self: *Looper, packets: Packets, side: io.Side) anyerror!void {
        if (!self.isOnQueue()) {
            log.writef(.err, "OOB writes must run on the looper queue", .{});
            return;
        }

        self.lock.lock();
        if (self.state != .started or self.mux_freed) {
            self.lock.unlock();
            return error.Cancelled;
        }
        const side_io = self.sideIO(side) orelse {
            self.lock.unlock();
            log.writef(.err, "Ignoring {s} packets, not attached", .{@tagName(side)});
            return;
        };
        const transform = side_io.transform_write;
        self.lock.unlock();

        const processed = if (transform) |callback|
            try self.callTransform(callback, packets)
        else
            packets;
        for (processed) |packet| {
            const written = side_io.native_io.write(packet, 0) catch |err| {
                return sideTaggedError(side, err);
            };
            if (written != packet.len) return error.WriteIncomplete;
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
        var pending = self.command_head;
        self.command_head = null;
        self.command_tail = null;

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
                .perform => |command| {
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
                .custom => |task| {
                    self.lock.unlock();
                    task.call() catch |err| {
                        self.lock.lock();
                        outcome.failure = self.failureFromTaggedError(err) orelse .{ .system = err };
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
        if (self.state == .stopping) {
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
            log.writef(.err, "Unable to attach {s} (fd={any})", .{ @tagName(side), descriptor.fd });
            self.queueCompletionLocked(completion, error.MuxFailure);
            return;
        }
        log.writef(.info, "Attach {s} (fd={any})", .{ @tagName(side), descriptor.fd });

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
            log.writef(.err, "Unable to retain {s}", .{@tagName(side)});
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
            log.writef(.err, "Ignoring enableRead(.{s}), not attached", .{@tagName(side)});
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
            log.writef(.err, "Ignoring enableWrite(.{s}), not attached", .{@tagName(side)});
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
            const did_complete = written == pending.data.len - pending.offset;
            self.lock.lock();
            if (did_complete) {
                const first = side_io.write_head.?;
                side_io.write_head = first.next;
                if (side_io.write_head == null) side_io.write_tail = null;
                side_io.write_offset = 0;
                self.allocator.free(first.data);
                self.allocator.destroy(first);
            } else {
                side_io.write_offset += written;
            }
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
        while (read_count < self.max_read_count and read_size < self.max_read_size) {
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
        node.deadline_ns = deadlineAfter(no_buf_retry_delay_ms);
        self.read_retries[index] = true;
        _ = self.insertScheduledNode(node);
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
        node.deadline_ns = deadlineAfter(no_buf_retry_delay_ms);
        self.write_retries[index] = true;
        _ = self.insertScheduledNode(node);
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
        if (failure) |reason| {
            log.writef(.err, "Finish looper with error: {s}", .{@tagName(reason)});
        } else {
            log.writef(.info, "Finish looper", .{});
        }

        self.lock.lock();
        if (self.state == .stopped) {
            self.lock.unlock();
            std.debug.assert(false);
            return;
        }
        self.state = .stopped;
        self.terminal_failure = failure;
        const pending = self.command_head;
        self.command_head = null;
        self.command_tail = null;
        self.cancelPendingLocked(pending);
        self.destroyCommandList(self.scheduled_head);
        self.scheduled_head = null;
        self.read_retries = .{ false, false };
        self.write_retries = .{ false, false };
        if (self.stop_completion) |completion| {
            completeNow(completion, if (failure) |reason| reason.err() else null);
            self.stop_completion = null;
        }
        self.releaseCompletionsLocked();
        self.condition.broadcast();
        self.lock.unlock();

        self.on_finish.call(failure);
    }

    fn cleanupAfterLoop(self: *Looper) void {
        self.lock.lock();
        if (self.mux_freed) {
            self.lock.unlock();
            return;
        }
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
        if (!self.mux_freed) _ = c.pp_mux_wake(self.mux);
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
        if (!self.mux_freed) {
            self.mux_freed = true;
            c.pp_mux_free(self.mux);
        }
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
            .link => self.link_buf_size,
            .tun => self.tun_buf_size,
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

    const PendingWrite = struct {
        data: []const u8,
        offset: usize,
    };

    fn pendingWrite(self: *Looper, side_io: *SideIO) ?PendingWrite {
        self.lock.lock();
        defer self.lock.unlock();
        const first = side_io.write_head orelse return null;
        return .{
            .data = first.data,
            .offset = side_io.write_offset,
        };
    }

    fn createCommandNode(self: *Looper, command: Command) std.mem.Allocator.Error!*CommandNode {
        const node = try self.allocator.create(CommandNode);
        node.* = .{ .command = command };
        return node;
    }

    fn appendCommandNode(self: *Looper, node: *CommandNode) void {
        node.next = null;
        if (self.command_tail) |tail| {
            tail.next = node;
        } else {
            self.command_head = node;
        }
        self.command_tail = node;
    }

    /// Inserts by absolute deadline, preserving FIFO order for equal deadlines.
    /// Returns whether `node` became the earliest scheduled command.
    fn insertScheduledNode(self: *Looper, node: *CommandNode) bool {
        node.next = null;
        const head = self.scheduled_head orelse {
            self.scheduled_head = node;
            return true;
        };
        if (node.deadline_ns < head.deadline_ns) {
            node.next = head;
            self.scheduled_head = node;
            return true;
        }

        var previous = head;
        while (previous.next) |next| {
            if (node.deadline_ns < next.deadline_ns) break;
            previous = next;
        }
        node.next = previous.next;
        previous.next = node;
        return false;
    }

    /// Moves every expired timer onto the serial command queue. Caller holds
    /// `lock`; callbacks still run later from `handleCommands`.
    fn promoteDueScheduledLocked(self: *Looper, now_ns: u64) void {
        while (self.scheduled_head) |node| {
            if (node.deadline_ns > now_ns) return;
            self.scheduled_head = node.next;
            node.next = null;
            self.clearRetryForCommand(node.command);
            if (self.state == .started) {
                self.appendCommandNode(node);
            } else {
                self.allocator.destroy(node);
            }
        }
    }

    fn waitTimeoutMsLocked(self: *Looper, now_ns: u64) c_int {
        if (self.command_head != null) return 0;
        const deadline_ns = if (self.scheduled_head) |node|
            node.deadline_ns
        else
            return -1;
        if (deadline_ns <= now_ns) return 0;

        const remaining_ns = deadline_ns - now_ns;
        var timeout_ms = remaining_ns / std.time.ns_per_ms;
        if (remaining_ns % std.time.ns_per_ms != 0) timeout_ms += 1;
        const max_timeout_ms: u64 = @intCast(std.math.maxInt(c_int));
        return @intCast(@min(timeout_ms, max_timeout_ms));
    }

    fn deadlineAfter(delay_ms: u64) u64 {
        const delay_ns = delay_ms *| @as(u64, std.time.ns_per_ms);
        return core.concurrency.monotonicNs() +| delay_ns;
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
                .detach => |command| self.queueCompletionLocked(command.completion, null),
                .perform => |command| self.queueCompletionLocked(command.completion, error.Cancelled),
                else => {},
            }
            self.allocator.destroy(node);
            pending = next;
        }
    }

    fn destroyCommandList(self: *Looper, head: ?*CommandNode) void {
        var current = head;
        while (current) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
    }

    fn destroyWriteList(self: *Looper, head: ?*WriteNode) void {
        var current = head;
        while (current) |node| {
            const next = node.next;
            self.allocator.free(node.data);
            self.allocator.destroy(node);
            current = next;
        }
    }

    fn queueCompletionLocked(
        self: *Looper,
        completion: *Completion,
        result: ?anyerror,
    ) void {
        completion.result = result;
        completion.next = null;
        if (self.completion_tail) |tail| {
            tail.next = completion;
        } else {
            self.completion_head = completion;
        }
        self.completion_tail = completion;
    }

    fn releaseCompletionsLocked(self: *Looper) void {
        var current = self.completion_head;
        while (current) |completion| {
            const next = completion.next;
            completion.next = null;
            completion.done = true;
            current = next;
        }
        self.completion_head = null;
        self.completion_tail = null;
    }

    fn completeNow(completion: *Completion, result: ?anyerror) void {
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

    fn sideTaggedError(side: io.Side, cause: io.Error) anyerror {
        return switch (side) {
            .link => switch (cause) {
                error.WouldBlock => error.LinkWouldBlock,
                error.Backpressure => error.LinkBackpressure,
                error.EndOfStream => error.LinkEndOfStream,
                error.LibcFailure => error.LinkLibcFailure,
                error.OutOfMemory => error.LinkOutOfMemory,
            },
            .tun => switch (cause) {
                error.WouldBlock => error.TunWouldBlock,
                error.Backpressure => error.TunBackpressure,
                error.EndOfStream => error.TunEndOfStream,
                error.LibcFailure => error.TunLibcFailure,
                error.OutOfMemory => error.TunOutOfMemory,
            },
        };
    }

    fn failureFromTaggedError(self: *Looper, err: anyerror) ?Failure {
        const item: struct { side: io.Side, cause: io.Error } = switch (err) {
            error.LinkWouldBlock => .{ .side = .link, .cause = error.WouldBlock },
            error.LinkBackpressure => .{ .side = .link, .cause = error.Backpressure },
            error.LinkEndOfStream => .{ .side = .link, .cause = error.EndOfStream },
            error.LinkLibcFailure => .{ .side = .link, .cause = error.LibcFailure },
            error.LinkOutOfMemory => .{ .side = .link, .cause = error.OutOfMemory },
            error.TunWouldBlock => .{ .side = .tun, .cause = error.WouldBlock },
            error.TunBackpressure => .{ .side = .tun, .cause = error.Backpressure },
            error.TunEndOfStream => .{ .side = .tun, .cause = error.EndOfStream },
            error.TunLibcFailure => .{ .side = .tun, .cause = error.LibcFailure },
            error.TunOutOfMemory => .{ .side = .tun, .cause = error.OutOfMemory },
            else => return null,
        };
        return .{ .io = .{
            .side = item.side,
            .cause = item.cause,
            .code = if (item.cause == error.LibcFailure)
                if (self.sideIO(item.side)) |side_io|
                    side_io.native_io.lastErrorCode()
                else
                    null
            else
                null,
        } };
    }
};
