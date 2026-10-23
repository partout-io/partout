// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const backend = @import("backend.zig");

/// WinRT pushes owned packets into queues; Go workers drain them on read.
/// Lifecycle calls are owner-serialized. Writes exclude descriptor replacement,
/// while callbacks use a separate lock so channel writes can trigger delivery.
pub const PassiveIO = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    lock: core.Mutex = .{},
    writes: core.Mutex = .{},
    ready: core.Condition = .{},
    complete: *const fn (usize, u32, i32) callconv(.c) void,
    link: ?net.LinkDescriptor = null,
    tun: ?net.TunDescriptor = null,
    closed: bool = true,
    sides: [2]Side = .{ .{}, .{} },
    failure: ?FailureReporter = null,

    const FailureReporter = struct { ctx: *anyopaque, report: *const fn (*anyopaque) void };
    const Packet = struct {
        data: []u8,
        source: net.SocketAddress,
        next: ?*Packet = null,
    };
    const Side = struct {
        owner: *PassiveIO = undefined,
        tag: net.Side = .link,
        attached: bool = false,
        packets: core.Fifo(Packet) = .{},
        count: usize = 0,
    };

    pub fn init(complete: *const fn (usize, u32, i32) callconv(.c) void) std.mem.Allocator.Error!PassiveIO {
        return .{ .complete = complete };
    }

    pub fn deinit(self: *PassiveIO) void {
        self.release();
        self.ready.deinit();
        self.writes.deinit();
        self.lock.deinit();
    }

    pub fn replaceLink(self: *PassiveIO, descriptor: net.LinkDescriptor) void {
        self.replace(.link, descriptor);
    }

    pub fn replaceTun(self: *PassiveIO, descriptor: net.TunDescriptor) void {
        self.replace(.tun, descriptor);
    }

    fn replace(self: *PassiveIO, comptime tag: net.Side, descriptor: if (tag == .link) net.LinkDescriptor else net.TunDescriptor) void {
        self.writes.lock();
        defer self.writes.unlock();
        self.detach(tag);
        self.lock.lock();
        if (tag == .tun and self.closed) {
            self.lock.unlock();
            descriptor.cleanup();
            return;
        }
        if (tag == .link) {
            self.link = descriptor;
            self.closed = false;
        } else self.tun = descriptor;
        const side = &self.sides[@intFromEnum(tag)];
        side.owner = self;
        side.tag = tag;
        side.attached = true;
        self.ready.broadcast();
        self.lock.unlock();
        descriptor.setOnReceive(onReceive, side) catch self.fail();
    }

    // Caller holds writes, but never the queue lock while draining callbacks.
    fn detach(self: *PassiveIO, comptime tag: net.Side) void {
        self.lock.lock();
        const side = &self.sides[@intFromEnum(tag)];
        side.attached = false;
        const descriptor = if (tag == .link) self.link else self.tun;
        if (tag == .link) self.link = null else self.tun = null;
        self.clear(side);
        self.ready.broadcast();
        self.lock.unlock();
        if (descriptor) |value| {
            value.stopWrites();
            value.setOnReceive(null, null) catch unreachable;
            value.cleanup();
        }
    }

    pub fn releaseLink(self: *PassiveIO) void {
        self.writes.lock();
        defer self.writes.unlock();
        self.detach(.link);
    }

    pub fn hasIO(self: *PassiveIO) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.link != null or self.tun != null;
    }

    pub fn activate(self: *PassiveIO) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.closed = false;
    }

    pub fn quiesce(self: *PassiveIO) void {
        self.lock.lock();
        self.closed = true;
        self.ready.broadcast();
        self.lock.unlock();
        // No admitted write may still borrow a Go buffer when this returns.
        self.writes.lock();
        self.writes.unlock();
    }

    pub fn release(self: *PassiveIO) void {
        self.quiesce();
        self.writes.lock();
        defer self.writes.unlock();
        self.detach(.link);
        self.detach(.tun);
    }

    fn clear(self: *PassiveIO, side: *Side) void {
        while (side.packets.take()) |packet| {
            self.allocator.free(packet.data);
            self.allocator.destroy(packet);
        }
        side.count = 0;
    }

    fn fail(self: *PassiveIO) void {
        self.lock.lock();
        const reporter = if (self.closed) null else self.failure;
        self.closed = true;
        self.ready.broadcast();
        self.lock.unlock();
        if (reporter) |value| value.report(value.ctx);
    }

    fn onReceive(raw: ?*anyopaque, bytes: [*c]const u8, length: usize, source: [*c]const net.SocketAddress, code: i32) callconv(.c) bool {
        const side: *Side = @ptrCast(@alignCast(raw.?));
        const self = side.owner;
        self.lock.lock();
        if (self.closed or !side.attached) {
            self.lock.unlock();
            return false;
        }
        if (code != 0 or (side.tag == .link and source == null)) {
            self.lock.unlock();
            self.fail();
            return false;
        }
        // Bound memory without pausing UDP delivery indefinitely. Drop newest.
        if (side.count >= 1024) {
            self.lock.unlock();
            return true;
        }
        self.enqueue(side, bytes[0..length], if (source == null) std.mem.zeroes(net.SocketAddress) else source[0]) catch {
            self.lock.unlock();
            self.fail();
            return false;
        };
        self.ready.broadcast();
        self.lock.unlock();
        return true;
    }

    fn enqueue(self: *PassiveIO, side: *Side, bytes: []const u8, source: net.SocketAddress) !void {
        const packet = try self.allocator.create(Packet);
        errdefer self.allocator.destroy(packet);
        packet.* = .{ .data = try self.allocator.dupe(u8, bytes), .source = source };
        side.packets.append(packet);
        side.count += 1;
    }

    pub fn transport(self: *PassiveIO, port: u16, mtu: u32) backend.StartTunnelPassive {
        return .{
            .link = .{ .local_port = port, .read = readLink, .write = writeLink },
            .tun = .{ .mtu = mtu, .read = readTun, .write = writeTun },
            .context = self,
        };
    }

    fn readLink(raw: ?*anyopaque, packets: [*c]c.wg_read_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.read(.link, packets, count, request);
    }

    fn readTun(raw: ?*anyopaque, packets: [*c]c.wg_read_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.read(.tun, packets, count, request);
    }

    fn read(self: *PassiveIO, tag: net.Side, packets: [*c]c.wg_read_packet, count: u32, request: usize) i32 {
        if (request == 0 or packets == null or count == 0 or count > c.WG_IO_MAX_BATCH) return c.WG_IO_INVALID;
        for (packets[0..count]) |packet| if (packet.data == null or packet.capacity == 0) return c.WG_IO_INVALID;
        self.lock.lock();
        const side = &self.sides[@intFromEnum(tag)];
        // Go also cancels reads during bind replacement. Bound the wait so it
        // can observe cancellation even without a host descriptor change.
        const deadline = core.concurrency.deadlineAfterMs(core.monotonicNs(), 100);
        while (!self.closed and side.count == 0 and core.monotonicNs() < deadline)
            self.ready.waitUntil(&self.lock, deadline);
        var completed: u32 = 0;
        if (!self.closed) for (packets[0..count]) |*output| {
            const packet = side.packets.take() orelse break;
            side.count -= 1;
            defer {
                self.allocator.free(packet.data);
                self.allocator.destroy(packet);
            }
            // Never deliver a truncated datagram as a valid WG packet.
            if (packet.data.len > output.capacity) break;
            @memcpy(output.data[0..packet.data.len], packet.data);
            output.size = @intCast(packet.data.len);
            output.source = .{ .address = packet.source.address, .scope_id = packet.source.scope_id, .port = packet.source.port, .family = packet.source.family };
            completed += 1;
        };
        const status: i32 = if (self.closed) c.WG_IO_CLOSED else if (completed != 0) c.WG_IO_OK else c.WG_IO_AGAIN;
        self.lock.unlock();
        self.complete(request, completed, status);
        return c.WG_IO_OK;
    }

    fn writeLink(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, destination: [*c]const c.wg_endpoint, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (destination == null or (destination[0].family != 4 and destination[0].family != 6) or
            (destination[0].family == 4 and destination[0].scope_id != 0)) return c.WG_IO_INVALID;
        const address = net.SocketAddress{ .address = destination[0].address, .scope_id = destination[0].scope_id, .port = destination[0].port, .family = destination[0].family };
        return self.write(.link, packets, count, address, request);
    }

    fn writeTun(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.write(.tun, packets, count, null, request);
    }

    fn write(self: *PassiveIO, comptime tag: net.Side, packets: [*c]const c.wg_packet, count: u32, destination: ?net.SocketAddress, request: usize) i32 {
        if (request == 0 or packets == null or count == 0 or count > c.WG_IO_MAX_BATCH) return c.WG_IO_INVALID;
        for (packets[0..count]) |packet| if (packet.size > 65535 or (packet.size != 0 and packet.data == null) or (tag == .tun and packet.size == 0)) return c.WG_IO_INVALID;
        self.writes.lock();
        self.lock.lock();
        const closed = self.closed;
        const descriptor = if (tag == .link) self.link else self.tun;
        self.lock.unlock();
        var completed: u32 = 0;
        var status: i32 = if (closed) c.WG_IO_CLOSED else c.WG_IO_AGAIN;
        if (!closed) if (descriptor) |value| {
            for (packets[0..count]) |packet| {
                const data: []const u8 = if (packet.size == 0) &.{} else packet.data[0..packet.size];
                const result = if (tag == .link) value.write(data, destination) else value.write(data);
                const failure = result catch {
                    status = c.WG_IO_INVALID;
                    break;
                };
                if (failure != null) {
                    status = c.WG_IO_INVALID;
                    break;
                }
                completed += 1;
            }
            if (completed == count) status = c.WG_IO_OK;
        };
        self.writes.unlock();
        if (status == c.WG_IO_AGAIN) {
            self.lock.lock();
            if (!self.closed and tag == .tun and self.tun == null)
                self.ready.waitUntil(&self.lock, core.concurrency.deadlineAfterMs(core.monotonicNs(), 100));
            status = if (self.closed) c.WG_IO_CLOSED else if (tag == .link) c.WG_IO_INVALID else c.WG_IO_AGAIN;
            self.lock.unlock();
            // A missing link during rebind is a dropped send, not a terminal error.
            self.complete(request, completed, status);
            return c.WG_IO_OK;
        }
        if (status == c.WG_IO_INVALID) self.fail();
        self.complete(request, completed, status);
        return c.WG_IO_OK;
    }
};
