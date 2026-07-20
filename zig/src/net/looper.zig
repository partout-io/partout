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

const actor_mod = @import("../core/actor.zig");
const core = @import("../core/exports.zig");
const io = @import("io.zig");

const c = io.c;
const log = std.log.scoped(.looper);

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
    pub const StartError = LoopActor.CreateError || error{AlreadyStarted};
    pub const AttachError = std.mem.Allocator.Error || error{
        Cancelled,
        MuxFailure,
        OperationCancelled,
    };

    const number_of_descriptors = 2;
    const no_buf_retry_delay_ms = 10;

    const State = enum {
        idle,
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
        remaining_ms: u64 = 0,
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

        fn detach(self: *SideIO, mux: c.pp_mux, failure: ?Failure) void {
            if (failure) |reason| {
                if (self.on_failure) |callback| callback.call(reason);
            }
            if (self.did_cleanup) return;
            self.did_cleanup = true;
            _ = c.pp_mux_delete(mux, self.fd);
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

    const LoopActor = actor_mod.Actor(
        Looper,
        void,
        error{},
        performActorMessage,
    );

    fn performActorMessage(_: *Looper, _: void) error{}!void {}

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
    scheduled_head: ?*CommandNode = null,
    scheduled_tail: ?*CommandNode = null,
    read_retries: [2]bool = .{ false, false },
    write_retries: [2]bool = .{ false, false },
    link: ?*SideIO = null,
    tun: ?*SideIO = null,
    stop_completion: ?*Completion = null,
    terminal_failure: ?Failure = null,
    next_side_id: u64 = 1,
    actor: ?*LoopActor = null,
    fd_set: ?DescriptorSet = null,
    scheduler_thread: ?std.Thread = null,
    scheduler_stopping: bool = false,
    deinitializing: bool = false,
    mux_freed: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        const mux = c.pp_mux_create(number_of_descriptors) orelse {
            log.err("Unable to create mux", .{});
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
        log.debug("Deinit Looper", .{});

        self.lock.lock();
        var link_to_detach: ?*SideIO = null;
        var tun_to_detach: ?*SideIO = null;
        var should_wake = false;
        if (self.state == .started) {
            // Match FdLooper.deinit: detach first, then wake the weakly-held
            // event loop without reporting a normal finish.
            link_to_detach = self.link;
            tun_to_detach = self.tun;
            self.state = .stopping;
            self.deinitializing = true;
            should_wake = true;
        }
        self.lock.unlock();
        if (link_to_detach) |side_io| side_io.detach(self.mux, null);
        if (tun_to_detach) |side_io| side_io.detach(self.mux, null);
        if (should_wake) _ = c.pp_mux_wake(self.mux);
        self.shutdownActor();

        self.lock.lock();
        self.scheduler_stopping = true;
        self.condition.broadcast();
        const scheduler_thread = self.scheduler_thread;
        self.scheduler_thread = null;
        self.lock.unlock();
        if (scheduler_thread) |thread| thread.join();

        self.lock.lock();
        if (self.link) |side_io| {
            side_io.detach(self.mux, null);
            side_io.destroyStorage(self.allocator);
            self.link = null;
        }
        if (self.tun) |side_io| {
            side_io.detach(self.mux, null);
            side_io.destroyStorage(self.allocator);
            self.tun = null;
        }
        self.destroyCommandList(self.command_head);
        self.command_head = null;
        self.command_tail = null;
        self.destroyCommandList(self.scheduled_head);
        self.scheduled_head = null;
        self.scheduled_tail = null;
        if (self.fd_set) |*fd_set| {
            fd_set.deinit();
            self.fd_set = null;
        }
        if (!self.mux_freed) {
            c.pp_mux_free(self.mux);
            self.mux_freed = true;
        }
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
        self.state = .started;
        self.scheduler_stopping = false;
        self.lock.unlock();

        const scheduler = std.Thread.spawn(.{}, schedulerMain, .{self}) catch |err| {
            self.lock.lock();
            self.state = .idle;
            self.lock.unlock();
            return err;
        };
        self.lock.lock();
        self.scheduler_thread = scheduler;
        self.lock.unlock();

        const fd_set = DescriptorSet.init(self.allocator) catch |err| {
            self.lock.lock();
            self.state = .idle;
            self.scheduler_stopping = true;
            self.condition.broadcast();
            self.scheduler_thread = null;
            self.lock.unlock();
            scheduler.join();
            return err;
        };
        self.fd_set = fd_set;
        c.pp_mux_set_on_readable(self.mux, onMuxReadable, &self.fd_set.?);
        c.pp_mux_set_on_writable(self.mux, onMuxWritable, &self.fd_set.?);

        log.info("Start looper", .{});
        const actor = LoopActor.createWithWaitCallbacks(self.allocator, self, .{
            .wait = actorWait,
            .wake_up = actorWakeUp,
        }) catch |err| {
            self.fd_set.?.deinit();
            self.fd_set = null;
            self.lock.lock();
            self.state = .idle;
            self.scheduler_stopping = true;
            self.condition.broadcast();
            self.scheduler_thread = null;
            self.lock.unlock();
            scheduler.join();
            return err;
        };
        self.lock.lock();
        self.actor = actor;
        self.lock.unlock();
    }

    pub fn stop(self: *Looper) anyerror!void {
        var completion = Completion{};

        self.lock.lock();
        switch (self.state) {
            .idle => {
                self.lock.unlock();
                return;
            },
            .started => {},
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
        _ = c.pp_mux_wake(self.mux);
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const result = completion.result;
        self.lock.unlock();

        self.shutdownActor();
        if (result) |err| return err;
    }

    pub fn isOnQueue(self: *Looper) bool {
        self.lock.lock();
        const actor = self.actor;
        self.lock.unlock();
        return if (actor) |item| item.isCurrentThread() else false;
    }

    pub fn perform(
        self: *Looper,
        comptime Result: type,
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque) anyerror!Result,
    ) anyerror!Result {
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
            log.err("Ignoring perform before start()", .{});
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
        _ = c.pp_mux_wake(self.mux);
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const command_result = completion.result;
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
        if (delay_ms) |delay| {
            const node = try self.createCommandNode(.{ .custom = task });
            node.remaining_ms = delay;
            self.appendScheduledNode(node);
            self.condition.broadcast();
            return;
        }
        if (self.state != .started) {
            log.err("Ignoring schedule before start()", .{});
            return;
        }
        const node = try self.createCommandNode(.{ .custom = task });
        self.appendCommandNode(node);
        _ = c.pp_mux_wake(self.mux);
    }

    /// Ownership of `arguments.pair.io` transfers only after successful attach.
    pub fn attach(self: *Looper, arguments: AttachArguments) AttachError!void {
        var completion = Completion{};

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            log.err("Ignoring attach before start()", .{});
            std.debug.assert(false);
            return;
        }
        const node = self.createCommandNode(.{ .attach = .{
            .arguments = arguments,
            .completion = &completion,
        } }) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.appendCommandNode(node);
        _ = c.pp_mux_wake(self.mux);
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        const result = completion.result;
        self.lock.unlock();
        if (result) |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.OperationCancelled => error.OperationCancelled,
            else => error.MuxFailure,
        };
    }

    pub fn detach(self: *Looper, side: io.Side) std.mem.Allocator.Error!void {
        var completion = Completion{};

        self.lock.lock();
        if (self.state != .started) {
            self.lock.unlock();
            log.err("Ignoring detach before start()", .{});
            std.debug.assert(false);
            return;
        }
        const node = self.createCommandNode(.{ .detach = .{
            .side = side,
            .completion = &completion,
        } }) catch |err| {
            self.lock.unlock();
            return err;
        };
        self.appendCommandNode(node);
        _ = c.pp_mux_wake(self.mux);
        while (!completion.done) {
            self.condition.wait(&self.lock);
        }
        self.lock.unlock();
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

    pub fn resumeReading(self: *Looper, side: io.Side) std.mem.Allocator.Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        const node = try self.createCommandNode(.{ .enable_read = .{
            .side = side,
            .id = null,
        } });
        self.appendCommandNode(node);
        _ = c.pp_mux_wake(self.mux);
    }

    pub fn write(
        self: *Looper,
        packets: Packets,
        side: io.Side,
        out_of_band: bool,
    ) anyerror!void {
        if (out_of_band) return self.writeOutOfBand(packets, side);

        self.lock.lock();
        const current = self.sideIO(side) orelse {
            self.lock.unlock();
            log.err("Ignoring {s} packets, not attached", .{@tagName(side)});
            return;
        };
        const id = current.id;
        const transform = current.transform_write;
        self.lock.unlock();

        const processed = if (transform) |callback|
            try callback.call(packets)
        else
            packets;

        self.lock.lock();
        defer self.lock.unlock();
        const attached = self.sideIO(side) orelse {
            log.err("Ignoring detached {s} during processing", .{@tagName(side)});
            return;
        };
        if (attached.id != id) {
            log.err("Ignoring detached {s} during processing", .{@tagName(side)});
            return;
        }

        const command = try self.createCommandNode(.{ .enable_write = .{
            .side = side,
            .id = null,
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
        _ = c.pp_mux_wake(self.mux);
    }

    pub fn writeQueued(self: *Looper, packets: Packets, side: io.Side) anyerror!void {
        return self.write(packets, side, false);
    }

    fn writeOutOfBand(self: *Looper, packets: Packets, side: io.Side) anyerror!void {
        if (!self.isOnQueue()) {
            log.err("OOB writes must run on the looper queue", .{});
            return;
        }
        const side_io = self.sideIO(side) orelse {
            log.err("Ignoring {s} packets, not attached", .{@tagName(side)});
            return;
        };
        const processed = if (side_io.transform_write) |callback|
            try callback.call(packets)
        else
            packets;
        for (processed) |packet| {
            const written = side_io.native_io.write(packet, 0) catch |err| {
                return sideTaggedError(side, err);
            };
            if (written != packet.len) return error.WriteIncomplete;
        }
    }

    fn actorWait(self: *Looper) bool {
        self.lock.lock();
        if (self.state == .stopped or self.mux_freed) {
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
            log.err("Looper: pp_mux_wait() failed (code={})", .{code});
            self.finish(.{ .wait = code });
            self.cleanupAfterLoop();
            return false;
        }
        if (fd_set.allocation_failed) {
            self.finish(.{ .system = error.OutOfMemory });
            self.cleanupAfterLoop();
            return false;
        }

        self.lock.lock();
        const released = self.deinitializing;
        self.lock.unlock();
        if (released) {
            log.info("Looper: released self", .{});
            self.cleanupAfterLoop();
            return false;
        }

        const command_outcome = self.handleCommands(fd_set);
        if (command_outcome.failure) |failure| {
            if (sideFailure(failure)) |item| {
                self.detachImmediately(item.side, item.failure);
                return true;
            }
            self.finish(failure);
            self.cleanupAfterLoop();
            return false;
        }
        if (!command_outcome.should_continue) {
            log.info("Looper: stop requested", .{});
            self.finish(null);
            self.cleanupAfterLoop();
            return false;
        }

        switch (self.process(fd_set)) {
            .ok => {},
            .side_failure => |item| self.detachImmediately(item.side, item.failure),
            .fatal => |failure| {
                self.finish(failure);
                self.cleanupAfterLoop();
                return false;
            },
        }
        return true;
    }

    fn actorWakeUp(self: *Looper) void {
        self.lock.lock();
        const can_wake = !self.mux_freed;
        self.lock.unlock();
        if (can_wake) _ = c.pp_mux_wake(self.mux);
    }

    fn schedulerMain(self: *Looper) void {
        while (true) {
            self.lock.lock();
            while (!self.scheduler_stopping and self.scheduled_head == null) {
                self.condition.wait(&self.lock);
            }
            if (self.scheduler_stopping) {
                self.lock.unlock();
                return;
            }
            self.lock.unlock();

            core.sleepMs(1);

            self.lock.lock();
            if (self.scheduler_stopping) {
                self.lock.unlock();
                return;
            }
            var previous: ?*CommandNode = null;
            var current = self.scheduled_head;
            var did_wake = false;
            while (current) |node| {
                const next = node.next;
                node.remaining_ms -|= 1;
                if (node.remaining_ms == 0) {
                    if (previous) |before| {
                        before.next = next;
                    } else {
                        self.scheduled_head = next;
                    }
                    if (self.scheduled_tail == node) self.scheduled_tail = previous;
                    node.next = null;

                    self.clearRetryForCommand(node.command);
                    if (self.state == .started) {
                        self.appendCommandNode(node);
                        did_wake = true;
                    } else {
                        self.allocator.destroy(node);
                    }
                } else {
                    previous = node;
                }
                current = next;
            }
            if (did_wake) _ = c.pp_mux_wake(self.mux);
            self.lock.unlock();
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
                    self.queueCompletionLocked(command.completion, null);
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
                    log.info("Stop looper", .{});
                    outcome.should_continue = false;
                },
            }
            self.allocator.destroy(node);
            pending = next;
            if (outcome.failure != null) {
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
            log.err("Unable to attach {s} (fd={any})", .{ @tagName(side), descriptor.fd });
            self.queueCompletionLocked(completion, error.MuxFailure);
            return;
        }
        log.info("Attach {s} (fd={any})", .{ @tagName(side), descriptor.fd });

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
            log.err("Unable to retain {s}", .{@tagName(side)});
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
        if (self.sideIO(side)) |side_io| {
            side_io.detach(self.mux, null);
            side_io.destroyStorage(self.allocator);
            self.setSideIO(side, null);
        }
        self.read_retries[sideIndex(side)] = false;
        self.write_retries[sideIndex(side)] = false;
        self.queueCompletionLocked(completion, null);
    }

    fn handleEnableReadLocked(self: *Looper, side: io.Side) io.Error!void {
        if (self.sideIO(side)) |side_io| {
            try side_io.setRead(self.mux, true);
        } else {
            log.err("Ignoring enableRead(.{s}), not attached", .{@tagName(side)});
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
            log.err("Ignoring enableWrite(.{s}), not attached", .{@tagName(side)});
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
        node.remaining_ms = no_buf_retry_delay_ms;
        self.read_retries[index] = true;
        self.appendScheduledNode(node);
        self.condition.broadcast();
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
        node.remaining_ms = no_buf_retry_delay_ms;
        self.write_retries[index] = true;
        self.appendScheduledNode(node);
        self.condition.broadcast();
        return null;
    }

    fn detachImmediately(self: *Looper, side: io.Side, failure: Failure) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.sideIO(side)) |side_io| {
            side_io.detach(self.mux, failure);
            side_io.destroyStorage(self.allocator);
            self.setSideIO(side, null);
        }
    }

    fn finish(self: *Looper, failure: ?Failure) void {
        if (failure) |reason| {
            log.err("Finish looper with error: {s}", .{@tagName(reason)});
        } else {
            log.info("Finish looper", .{});
        }

        self.lock.lock();
        if (self.state == .stopped) {
            self.lock.unlock();
            std.debug.assert(false);
            return;
        }
        self.state = .stopped;
        self.terminal_failure = failure;
        if (self.stop_completion) |completion| {
            completeNow(completion, if (failure) |reason| reason.err() else null);
            self.stop_completion = null;
        }
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
        // Publish mux unavailability before releasing the lock so an actor
        // shutdown racing `finish()` cannot wake a freed mux.
        self.mux_freed = true;
        self.lock.unlock();

        if (self.link) |side_io| side_io.detach(self.mux, null);
        if (self.tun) |side_io| side_io.detach(self.mux, null);

        c.pp_mux_free(self.mux);
        self.lock.lock();
        if (self.fd_set) |*fd_set| {
            fd_set.deinit();
            self.fd_set = null;
        }
        self.condition.broadcast();
        self.lock.unlock();
    }

    fn shutdownActor(self: *Looper) void {
        self.lock.lock();
        const actor = self.actor;
        self.actor = null;
        self.lock.unlock();
        if (actor) |item| item.deinit();
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

    fn appendScheduledNode(self: *Looper, node: *CommandNode) void {
        node.next = null;
        if (self.scheduled_tail) |tail| {
            tail.next = node;
        } else {
            self.scheduled_head = node;
        }
        self.scheduled_tail = node;
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
