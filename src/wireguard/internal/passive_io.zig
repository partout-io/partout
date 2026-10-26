// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const backend = @import("backend.zig");
const Endpoint = c.wg_endpoint;

/// Native callbacks fill waiting Go reads directly, queuing owned packets otherwise.
/// Lifecycle calls are owner-serialized. Writes exclude descriptor replacement,
/// while callbacks use a separate lock so channel writes can trigger delivery.
pub const PassiveIO = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    lock: core.Mutex = .{},
    writes: core.Mutex = .{},
    ready: core.Condition = .{},
    complete: *const fn (usize, u32, i32) callconv(.c) void,
    link: ?*net.CallbackIO = null,
    tun: ?*net.CallbackIO = null,
    closed: bool = true,
    sides: [2]Side = .{ .{}, .{} },
    failure: ?FailureReporter = null,

    const FailureReporter = struct { ctx: *anyopaque, report: *const fn (*anyopaque) void };
    const Packet = struct {
        data: []u8,
        source: net.SocketAddress,
        next: ?*Packet = null,
    };
    // Stack-owned by a Go read call. All buffer access and list operations use
    // lock; the reader unlinks itself before unlocking and completing the call.
    const PendingRead = struct {
        packets: []c.wg_read_packet,
        completed: u32 = 0,
        interrupted: bool = false,
        next: ?*PendingRead = null,
    };
    const Side = struct {
        owner: *PassiveIO = undefined,
        tag: net.Side = .link,
        attached: bool = false,
        packets: core.Fifo(Packet) = .{},
        count: usize = 0,
        readers: core.Fifo(PendingRead) = .{},

        fn cancelReads(self: *Side) void {
            while (self.readers.take()) |reader| reader.interrupted = true;
        }
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
        const value = net.CallbackIO.create(self.allocator, if (tag == .link) .{ .link = descriptor } else .{ .tun = descriptor }) catch {
            self.lock.unlock();
            self.fail();
            return;
        };
        if (tag == .link) {
            self.link = value;
            self.closed = false;
        } else self.tun = value;
        const side = &self.sides[@intFromEnum(tag)];
        side.owner = self;
        side.tag = tag;
        side.attached = true;
        self.ready.broadcast();
        self.lock.unlock();
        value.setOnReceive(onReceive, side) catch self.fail();
    }

    // Caller holds writes, but never the queue lock while draining callbacks.
    fn detach(self: *PassiveIO, comptime tag: net.Side) void {
        self.lock.lock();
        const side = &self.sides[@intFromEnum(tag)];
        side.attached = false;
        side.cancelReads();
        const descriptor = if (tag == .link) self.link else self.tun;
        if (tag == .link) self.link = null else self.tun = null;
        self.clear(side);
        self.ready.broadcast();
        self.lock.unlock();
        if (descriptor) |value| {
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
        for (&self.sides) |*side| side.cancelReads();
        self.ready.broadcast();
        self.lock.unlock();
        // No submission may still borrow a Go buffer when this returns.
        // Pending native writes own copies and are discarded on detach.
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
        for (&self.sides) |*side| side.cancelReads();
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
        const address = if (source == null) std.mem.zeroes(net.SocketAddress) else source[0];
        if (side.readers.head) |reader| {
            const output = &reader.packets[reader.completed];
            // Consume an oversized datagram without delivering truncated input.
            // Finish this wait just as the queued read path does on a drop.
            if (length > output.capacity) {
                _ = side.readers.take();
                reader.interrupted = true;
            } else {
                @memcpy(output.data[0..length], bytes[0..length]);
                output.size = @intCast(length);
                output.source = toEndpoint(address);
                reader.completed += 1;
                if (reader.completed == reader.packets.len) _ = side.readers.take();
            }
            self.ready.broadcast();
            self.lock.unlock();
            return true;
        }
        // Bound memory without pausing UDP delivery indefinitely. Drop newest.
        if (side.count >= 1024) {
            self.lock.unlock();
            return true;
        }
        self.enqueue(side, bytes[0..length], address) catch {
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
        if (!validRead(packets, count, request)) return c.WG_IO_INVALID;
        self.lock.lock();
        const side = &self.sides[@intFromEnum(tag)];
        var completed: u32 = 0;
        if (!self.closed and side.count == 0) {
            var reader = PendingRead{ .packets = packets[0..count] };
            side.readers.append(&reader);
            // Go also cancels reads during bind replacement. Bound the wait so
            // it can observe cancellation without a host descriptor change.
            const deadline = core.concurrency.deadlineAfterMs(core.monotonicNs(), 100);
            while (!self.closed and !reader.interrupted and reader.completed == 0 and core.monotonicNs() < deadline)
                self.ready.waitUntil(&self.lock, deadline);
            _ = side.readers.remove(&reader);
            completed = if (self.closed) 0 else reader.completed;
        } else if (!self.closed) for (packets[0..count]) |*output| {
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
            output.source = toEndpoint(packet.source);
            completed += 1;
        };
        const status: i32 = if (self.closed) c.WG_IO_CLOSED else if (completed != 0) c.WG_IO_OK else c.WG_IO_AGAIN;
        self.lock.unlock();
        self.complete(request, completed, status);
        return c.WG_IO_OK;
    }

    pub const testing = struct {
        pub fn attach(self: *PassiveIO, tag: net.Side) void {
            self.lock.lock();
            defer self.lock.unlock();
            const side = &self.sides[@intFromEnum(tag)];
            side.owner = self;
            side.tag = tag;
            side.attached = true;
            self.closed = false;
        }

        pub fn receive(self: *PassiveIO, tag: net.Side, bytes: []const u8, source: ?*const net.SocketAddress, code: i32) bool {
            return onReceive(&self.sides[@intFromEnum(tag)], bytes.ptr, bytes.len, source, code);
        }

        pub fn pendingReads(self: *PassiveIO, tag: net.Side) usize {
            self.lock.lock();
            defer self.lock.unlock();
            var count: usize = 0;
            var current = self.sides[@intFromEnum(tag)].readers.head;
            while (current) |reader| : (current = reader.next) count += 1;
            return count;
        }
    };

    fn writeLink(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, destination: [*c]const c.wg_endpoint, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        if (destination == null) return c.WG_IO_INVALID;
        const address = fromEndpoint(destination.*) catch return c.WG_IO_INVALID;
        return self.write(.link, packets, count, address, request);
    }

    fn writeTun(raw: ?*anyopaque, packets: [*c]const c.wg_packet, count: u32, request: usize) callconv(.c) i32 {
        const self: *PassiveIO = @ptrCast(@alignCast(raw orelse return c.WG_IO_INVALID));
        return self.write(.tun, packets, count, null, request);
    }

    fn write(self: *PassiveIO, comptime tag: net.Side, packets: [*c]const c.wg_packet, count: u32, destination: ?net.SocketAddress, request: usize) i32 {
        if (!validWrite(tag, packets, count, request)) return c.WG_IO_INVALID;
        self.writes.lock();
        self.lock.lock();
        const closed = self.closed;
        const descriptor = if (tag == .link) self.link else self.tun;
        self.lock.unlock();
        var completed: u32 = 0;
        var status: i32 = if (closed) c.WG_IO_CLOSED else c.WG_IO_AGAIN;
        var dropped = false;
        if (!closed) if (descriptor) |value| {
            for (packets[0..count]) |packet| {
                const data: []const u8 = if (packet.size == 0) &.{} else packet.data[0..packet.size];
                const result = value.write(data, destination);
                if (result != .ok) {
                    dropped = result == .dropped;
                    status = if (result == .again) c.WG_IO_AGAIN else c.WG_IO_INVALID;
                    break;
                }
                completed += 1;
            }
            if (completed == count) status = c.WG_IO_OK;
        };
        self.writes.unlock();
        if (status == c.WG_IO_AGAIN) {
            self.lock.lock();
            if (!self.closed and (descriptor != null or (tag == .tun and self.tun == null)))
                self.ready.waitUntil(&self.lock, core.concurrency.deadlineAfterMs(core.monotonicNs(), 100));
            status = if (self.closed) c.WG_IO_CLOSED else if (tag == .link and descriptor == null) c.WG_IO_INVALID else c.WG_IO_AGAIN;
            self.lock.unlock();
            // A missing link during rebind is a dropped send, not a terminal error.
            self.complete(request, completed, status);
            return c.WG_IO_OK;
        }
        if (status == c.WG_IO_INVALID and !dropped) self.fail();
        self.complete(request, completed, status);
        return c.WG_IO_OK;
    }
};

fn validRead(packets: [*c]c.wg_read_packet, count: u32, request: usize) bool {
    if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return false;
    for (packets[0..count]) |packet| if (packet.data == null or packet.capacity == 0) return false;
    return true;
}

fn validWrite(side: net.Side, packets: [*c]const c.wg_packet, count: u32, request: usize) bool {
    if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return false;
    for (packets[0..count]) |packet| if (packet.size > 65535 or (packet.size != 0 and packet.data == null) or (side == .tun and packet.size == 0)) return false;
    return true;
}

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

pub const testing = struct {
    pub const abi = c;
};
