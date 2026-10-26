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
    closed: bool = true,
    // Quiesce is reversible; a failed transport requires link replacement.
    failed: bool = false,
    sides: [2]Side = .{ .{ .tag = .link }, .{ .tag = .tun } },
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
        tag: net.Side,
        transport: ?*net.PacketTransport = null,
        attached: bool = false,
        packets: core.Fifo(Packet) = .{},
        count: usize = 0,
        readers: core.Fifo(PendingRead) = .{},

        fn cancelReads(self: *Side) void {
            while (self.readers.take()) |reader| reader.interrupted = true;
        }

        fn clear(self: *Side, allocator: std.mem.Allocator) void {
            while (self.packets.take()) |packet| {
                allocator.free(packet.data);
                allocator.destroy(packet);
            }
            self.count = 0;
        }

        fn enqueue(self: *Side, allocator: std.mem.Allocator, bytes: []const u8, source: net.SocketAddress) !void {
            const packet = try allocator.create(Packet);
            errdefer allocator.destroy(packet);
            packet.* = .{ .data = try allocator.dupe(u8, bytes), .source = source };
            self.packets.append(packet);
            self.count += 1;
        }

        fn readQueued(self: *Side, allocator: std.mem.Allocator, outputs: []c.wg_read_packet) u32 {
            var completed: u32 = 0;
            for (outputs) |*output| {
                const packet = self.packets.take() orelse break;
                self.count -= 1;
                defer {
                    allocator.free(packet.data);
                    allocator.destroy(packet);
                }
                if (!copyPacket(output, packet.data, packet.source)) break;
                completed += 1;
            }
            return completed;
        }
    };

    const BatchResult = struct {
        count: u32 = 0,
        status: i32,
        fatal: bool = false,
    };

    fn sideFor(self: *PassiveIO, tag: net.Side) *Side {
        return &self.sides[@intFromEnum(tag)];
    }

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
        self.replace(.{ .link = descriptor });
    }

    pub fn replaceTun(self: *PassiveIO, descriptor: net.TunDescriptor) void {
        self.replace(.{ .tun = descriptor });
    }

    fn replace(self: *PassiveIO, descriptor: net.PacketTransport.Descriptor) void {
        const tag = std.meta.activeTag(descriptor);
        const side = self.sideFor(tag);
        self.writes.lock();
        defer self.writes.unlock();
        self.detach(tag);
        self.lock.lock();
        if (tag == .tun and self.closed) {
            self.lock.unlock();
            net.PacketTransport.releaseDescriptor(descriptor);
            return;
        }
        if (tag == .link) {
            self.closed = false;
            self.failed = false;
        }
        const packet_transport = net.PacketTransport.create(self.allocator, descriptor) catch {
            self.lock.unlock();
            self.fail();
            return;
        };
        side.transport = packet_transport;
        side.owner = self;
        side.attached = true;
        self.ready.broadcast();
        self.lock.unlock();
        packet_transport.setOnReceive(onReceive, side) catch self.fail();
    }

    // Caller holds writes, but never the queue lock while draining callbacks.
    fn detach(self: *PassiveIO, tag: net.Side) void {
        self.lock.lock();
        const side = self.sideFor(tag);
        // An initial TUN commit can satisfy reads waiting before attachment.
        // Replacing an attached descriptor cancels that descriptor's readers.
        if (side.attached) side.cancelReads();
        side.attached = false;
        const packet_transport = side.transport;
        side.transport = null;
        side.clear(self.allocator);
        self.ready.broadcast();
        self.lock.unlock();
        if (packet_transport) |value| value.cleanup();
    }

    pub fn releaseLink(self: *PassiveIO) void {
        self.writes.lock();
        defer self.writes.unlock();
        self.detach(.link);
    }

    pub fn hasIO(self: *PassiveIO) bool {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.sides) |side| if (side.transport != null) return true;
        return false;
    }

    pub fn activate(self: *PassiveIO) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.failed) return;
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

    fn fail(self: *PassiveIO) void {
        self.lock.lock();
        if (self.closed) {
            self.lock.unlock();
            return;
        }
        const reporter = self.failure;
        self.failed = true;
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
            // A quiesced descriptor may be reused on activation. Discard input
            // without pausing its producer; detach alone ends delivery.
            const keep_receiving = side.attached;
            self.lock.unlock();
            return keep_receiving;
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
            if (!copyPacket(output, bytes[0..length], address)) {
                _ = side.readers.take();
                reader.interrupted = true;
            } else {
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
        side.enqueue(self.allocator, bytes[0..length], address) catch {
            self.lock.unlock();
            self.fail();
            return false;
        };
        self.ready.broadcast();
        self.lock.unlock();
        return true;
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
        if (self.closed) {
            self.lock.unlock();
            return self.completeRequest(request, .{ .status = c.WG_IO_CLOSED });
        }
        const side = self.sideFor(tag);
        const completed = if (side.count != 0)
            side.readQueued(self.allocator, packets[0..count])
        else
            self.waitForPackets(side, packets[0..count]);
        const status: i32 = if (self.closed) c.WG_IO_CLOSED else if (completed != 0) c.WG_IO_OK else c.WG_IO_AGAIN;
        self.lock.unlock();
        return self.completeRequest(request, .{ .count = completed, .status = status });
    }

    // Caller holds lock throughout registration and removal. Waiting releases
    // it so the producer can fill the borrowed buffers. Go observes cancellation
    // between requests, so even an idle read must finish within 100 ms.
    fn waitForPackets(self: *PassiveIO, side: *Side, outputs: []c.wg_read_packet) u32 {
        var reader = PendingRead{ .packets = outputs };
        side.readers.append(&reader);
        defer _ = side.readers.remove(&reader);
        const deadline = core.concurrency.deadlineAfterMs(core.monotonicNs(), 100);
        while (!self.closed and !reader.interrupted and reader.completed == 0 and core.monotonicNs() < deadline)
            self.ready.waitUntil(&self.lock, deadline);
        return if (self.closed) 0 else reader.completed;
    }

    fn completeRequest(self: *PassiveIO, request: usize, result: BatchResult) i32 {
        self.complete(request, result.count, result.status);
        return c.WG_IO_OK;
    }

    pub const testing = struct {
        pub fn attach(self: *PassiveIO, tag: net.Side) void {
            self.lock.lock();
            defer self.lock.unlock();
            const side = self.sideFor(tag);
            side.owner = self;
            side.tag = tag;
            side.attached = true;
            self.closed = false;
            self.failed = false;
        }

        pub fn receive(self: *PassiveIO, tag: net.Side, bytes: []const u8, source: ?*const net.SocketAddress, code: i32) bool {
            return onReceive(self.sideFor(tag), bytes.ptr, bytes.len, source, code);
        }

        pub fn pendingReads(self: *PassiveIO, tag: net.Side) usize {
            self.lock.lock();
            defer self.lock.unlock();
            var count: usize = 0;
            var current = self.sideFor(tag).readers.head;
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

    fn write(self: *PassiveIO, tag: net.Side, packets: [*c]const c.wg_packet, count: u32, destination: ?net.SocketAddress, request: usize) i32 {
        if (!validWrite(tag, packets, count, request)) return c.WG_IO_INVALID;
        self.writes.lock();
        self.lock.lock();
        if (self.closed) {
            self.lock.unlock();
            self.writes.unlock();
            return self.completeRequest(request, .{ .status = c.WG_IO_CLOSED });
        }
        const packet_transport = self.sideFor(tag).transport;
        self.lock.unlock();
        // A missing link is a dropped send during rebind. A missing TUN waits
        // for initial commit. Neither is a terminal transport failure.
        var result = if (packet_transport) |value|
            writePackets(value, packets[0..count], destination)
        else
            BatchResult{ .status = switch (tag) {
                .link => c.WG_IO_INVALID,
                .tun => c.WG_IO_AGAIN,
            } };
        self.writes.unlock();
        if (result.status == c.WG_IO_AGAIN) result.status = self.waitForRetry();
        if (result.fatal) self.fail();
        return self.completeRequest(request, result);
    }

    fn writePackets(packet_transport: *net.PacketTransport, packets: []const c.wg_packet, destination: ?net.SocketAddress) BatchResult {
        var result = BatchResult{ .status = c.WG_IO_OK };
        for (packets) |packet| {
            const bytes: []const u8 = if (packet.size == 0) &.{} else packet.data[0..packet.size];
            switch (packet_transport.write(bytes, destination)) {
                .ok => result.count += 1,
                .again => {
                    result.status = c.WG_IO_AGAIN;
                    return result;
                },
                .dropped => {
                    result.status = c.WG_IO_INVALID;
                    return result;
                },
                .failed => return .{ .count = result.count, .status = c.WG_IO_INVALID, .fatal = true },
            }
        }
        return result;
    }

    fn waitForRetry(self: *PassiveIO) i32 {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.closed)
            self.ready.waitUntil(&self.lock, core.concurrency.deadlineAfterMs(core.monotonicNs(), 100));
        return if (self.closed) c.WG_IO_CLOSED else c.WG_IO_AGAIN;
    }
};

fn copyPacket(output: *c.wg_read_packet, bytes: []const u8, source: net.SocketAddress) bool {
    // An oversized datagram is discarded, never delivered as truncated input.
    if (bytes.len > output.capacity) return false;
    @memcpy(output.data[0..bytes.len], bytes);
    output.size = @intCast(bytes.len);
    output.source = toEndpoint(source);
    return true;
}

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
