// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const backend = @import("backend.zig");
const Endpoint = c.wg_endpoint;

/// Go packet bridge only. The daemon owns every descriptor and attachment.
/// The daemon lends Go buffers to native I/O and cancels writes on detach.
pub const PassiveIO = struct {
    lock: @import("../../core/exports.zig").Mutex = .{},
    reads: [2]ReadSlot = .{ .{}, .{} },
    allocator: std.mem.Allocator,
    backend: backend.Backend,
    looper: ?*net.Looper = null,
    handle: i32 = -1,
    startup: ?*Startup = null,
    state: std.atomic.Value(State) = .init(.closed),

    const State = enum(u8) { closed, paused, active };

    pub fn start(self: *PassiveIO, remote: net.RemoteDescriptor, mtu: u32, settings: [:0]const u8) !void {
        if (self.startup != null or remote.local_port == 0 or remote.looper.implementation != .experimental) return error.TransportFailure;
        if (self.backend.vtable.complete_io == null) return error.TransportFailure;
        self.looper = remote.looper;
        self.state.store(.active, .release);
        errdefer self.state.store(.closed, .release);
        const pending = try self.allocator.create(Startup);
        errdefer self.allocator.destroy(pending);
        const owned_settings = try self.allocator.dupeZ(u8, settings);
        errdefer self.allocator.free(owned_settings);
        pending.* = .{ .owner = self, .settings = owned_settings, .port = remote.local_port, .mtu = mtu };
        pending.thread = try std.Thread.spawn(.{}, Startup.run, .{pending});
        self.startup = pending;
    }

    // Only the blocking Go activation runs off-queue. Its result is consumed on
    // the looper, or after detachment when stop joins the worker.
    const Startup = struct {
        owner: *PassiveIO,
        settings: [:0]const u8,
        port: u16,
        mtu: u32,
        thread: std.Thread = undefined,
        done: std.atomic.Value(bool) = .init(false),
        result: backend.Error!i32 = undefined,

        fn run(self: *Startup) void {
            defer self.done.store(true, .release);
            const owner = self.owner;
            if (owner.handle >= 0) {
                self.result = if ((owner.backend.setConfig(owner.allocator, owner.handle, self.settings) catch -1) == 0) owner.handle else error.TransportFailure;
                return;
            }
            self.result = owner.backend.turnOn(owner.allocator, self.settings, .{ .passive = .{
                .link = .{ .local_port = self.port, .read = readLink, .write = writeLink },
                .tun = .{ .mtu = self.mtu, .read = readTun, .write = writeTun },
                .context = owner,
            } });
        }
    };

    pub fn pollStart(self: *PassiveIO) !bool {
        const pending = self.startup orelse return self.handle >= 0;
        if (!pending.done.load(.acquire)) return false;
        try self.joinStart();
        return true;
    }

    fn joinStart(self: *PassiveIO) !void {
        const pending = self.startup orelse return;
        pending.thread.join();
        defer self.allocator.destroy(pending);
        defer self.allocator.free(pending.settings);
        self.startup = null;
        const handle = try pending.result;
        if (handle < 0) return error.TransportFailure;
        self.handle = handle;
    }

    /// Runs on the looper. Stop admission before the daemon detaches native I/O.
    /// Read loans cannot be active here: acquire/release also run on this queue.
    pub fn quiesce(self: *PassiveIO) void {
        self.lock.lock();
        self.state.store(.closed, .release);
        var requests: [2]usize = .{ 0, 0 };
        for (&self.reads, &requests) |*slot, *request| {
            request.* = slot.request;
            for (slot.buffers[0..slot.count]) |*buffer| buffer.* = .{ .data = &.{} };
            slot.request = 0;
            slot.packets = null;
            slot.count = 0;
        }
        self.lock.unlock();
        if (self.backend.vtable.complete_io) |complete| {
            for (requests) |request| if (request != 0) {
                complete(request, 0, c.WG_IO_CLOSED);
            };
        }
    }

    /// Joins Go only after the daemon has detached I/O and completed writes.
    pub fn stop(self: *PassiveIO) void {
        self.quiesce();
        self.joinStart() catch {};
        if (self.handle >= 0) self.backend.turnOff(self.handle);
        self.handle = -1;
    }

    pub fn readBuffers(self: *PassiveIO, side: net.Side) net.Looper.ReadBuffers {
        const slot = &self.reads[if (side == .link) @as(usize, 0) else 1];
        slot.owner = self;
        return .{ .context = slot, .acquire = ReadSlot.acquire, .release = ReadSlot.release };
    }

    const ReadSlot = struct {
        owner: *PassiveIO = undefined,
        request: usize = 0,
        packets: [*c]c.wg_read_packet = null,
        count: usize = 0,
        buffers: [c.WG_IO_MAX_BATCH]net.Looper.ReadBuffer = undefined,

        fn acquire(raw: ?*anyopaque) []net.Looper.ReadBuffer {
            const slot: *ReadSlot = @ptrCast(@alignCast(raw.?));
            slot.owner.lock.lock();
            defer slot.owner.lock.unlock();
            return slot.buffers[0..slot.count];
        }
        fn release(raw: ?*anyopaque, _: []net.Looper.ReadBuffer, result: net.Looper.IOResult) void {
            const slot: *ReadSlot = @ptrCast(@alignCast(raw.?));
            const owner = slot.owner;
            owner.lock.lock();
            if (slot.request == 0 or (result.count == 0 and result.failure == null)) {
                owner.lock.unlock();
                return;
            }
            for (slot.buffers[0..result.count], slot.packets[0..result.count]) |buffer, *packet| {
                packet.size = @intCast(buffer.size);
                if (buffer.source) |source| packet.source = toEndpoint(source);
            }
            const request = slot.request;
            for (slot.buffers[0..slot.count]) |*buffer| buffer.* = .{ .data = &.{} };
            slot.request = 0;
            slot.packets = null;
            slot.count = 0;
            owner.lock.unlock();
            owner.backend.vtable.complete_io.?(request, @intCast(result.count), ioStatus(result));
        }
    };

    fn readLink(raw: ?*anyopaque, packets: [*c]c.wg_read_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.readBatch(.link, packets, count, request);
    }
    fn readTun(raw: ?*anyopaque, packets: [*c]c.wg_read_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.readBatch(.tun, packets, count, request);
    }
    fn readBatch(self: *PassiveIO, side: net.Side, packets: [*c]c.wg_read_packet, count: u32, request: usize) i32 {
        if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return c.WG_IO_INVALID;
        for (packets[0..count]) |packet| if (packet.data == null or packet.capacity == 0) {
            return c.WG_IO_INVALID;
        };
        self.lock.lock();
        defer self.lock.unlock();
        if (self.state.load(.acquire) == .closed) return c.WG_IO_CLOSED;
        const slot = &self.reads[if (side == .link) @as(usize, 0) else 1];
        if (slot.request != 0) return c.WG_IO_INVALID;
        for (packets[0..count], slot.buffers[0..count]) |packet, *buffer| {
            buffer.* = .{ .data = packet.data[0..packet.capacity] };
        }
        slot.request = request;
        slot.packets = packets;
        slot.count = count;
        const looper = self.looper.?;
        const attached = if (side == .link) looper.isLinkAttached() else looper.isTunAttached();
        if (attached and self.state.load(.acquire) == .active) looper.resumeReading(side) catch {
            for (slot.buffers[0..slot.count]) |*buffer| buffer.* = .{ .data = &.{} };
            slot.request = 0;
            slot.packets = null;
            slot.count = 0;
            return c.WG_IO_CLOSED;
        };
        return c.WG_IO_OK;
    }

    const WriteLoan = struct {
        allocator: std.mem.Allocator,
        complete: *const fn (usize, u32, i32) callconv(.c) void,
        request: usize,
        packets: [c.WG_IO_MAX_BATCH][]const u8 = undefined,
        fn finish(raw: ?*anyopaque, result: net.Looper.IOResult) void {
            const self: *WriteLoan = @ptrCast(@alignCast(raw.?));
            const complete = self.complete;
            const request = self.request;
            self.allocator.destroy(self);
            complete(request, @intCast(result.count), ioStatus(result));
        }
    };
    fn ioStatus(result: net.Looper.IOResult) i32 {
        if (result.failure) |err| return if (err == error.Cancelled) c.WG_IO_CLOSED else c.WG_IO_INVALID;
        return c.WG_IO_OK;
    }
    fn writeLink(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, destination: [*c]const Endpoint, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (destination == null) return c.WG_IO_INVALID;
        const address = fromEndpoint(destination.*) catch return c.WG_IO_INVALID;
        return self.writeBorrowed(packets, count, .link, address, request);
    }
    fn writeTun(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.writeBorrowed(packets, count, .tun, null, request);
    }
    fn writeBorrowed(self: *PassiveIO, packets: [*c]const c.wg_packet, count: u32, side: net.Side, destination: ?net.SocketAddress, request: usize) i32 {
        if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return c.WG_IO_INVALID;
        self.lock.lock();
        defer self.lock.unlock();
        switch (self.state.load(.acquire)) {
            .closed => return c.WG_IO_CLOSED,
            .paused => return c.WG_IO_INVALID,
            .active => {},
        }
        const loan = self.allocator.create(WriteLoan) catch return c.WG_IO_INVALID;
        loan.* = .{ .allocator = self.allocator, .complete = self.backend.vtable.complete_io.?, .request = request };
        for (packets[0..count], loan.packets[0..count]) |packet, *entry| {
            if (packet.size > 65535 or (packet.size != 0 and packet.data == null) or (side == .tun and packet.size == 0)) {
                self.allocator.destroy(loan);
                return c.WG_IO_INVALID;
            }
            entry.* = if (packet.size == 0) &.{} else packet.data[0..packet.size];
        }
        self.looper.?.writeBorrowed(loan.packets[0..count], side, destination, .{ .context = loan, .callback = WriteLoan.finish }) catch {
            self.allocator.destroy(loan);
            return c.WG_IO_CLOSED;
        };
        return c.WG_IO_OK;
    }
};

fn toEndpoint(address: net.SocketAddress) Endpoint {
    return .{
        .address = address.address,
        .scope_id = address.scope_id,
        .port = address.port,
        .family = address.family,
    };
}

fn fromEndpoint(endpoint: Endpoint) !net.SocketAddress {
    if (endpoint.family != 4 and endpoint.family != 6) return error.InvalidAddressFamily;
    if (endpoint.family == 4 and endpoint.scope_id != 0) return error.InvalidScope;
    var address = std.mem.zeroes(net.SocketAddress);
    address.address = endpoint.address;
    address.scope_id = endpoint.scope_id;
    address.port = endpoint.port;
    address.family = endpoint.family;
    return address;
}
