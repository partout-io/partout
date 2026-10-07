// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

//! UDP batching for looper v2. Borrows buffers directly and keeps the existing
//! scalar path for small buffers, unsupported syscalls and packet errors.
const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");
const helpers = @import("looper_helpers.zig");

pub const UDPBatch = struct {
    fd: i32,
    dual_stack: bool,
    can_read: bool = true,
    can_write: bool = true,
    const batch_size = 16;
    const max_datagram = 65535;
    const mapped_prefix = [_]u8{0} ** 10 ++ .{ 0xff, 0xff };

    pub fn init(fd: i32, family: u8) ?UDPBatch {
        var v6_only: c_int = 1;
        if (family == 6) {
            var len: u32 = @sizeOf(c_int);
            if (linux.errno(linux.getsockopt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, std.mem.asBytes(&v6_only), &len)) != .SUCCESS) return null;
        }
        return .{ .fd = fd, .dual_stack = family == 6 and v6_only == 0 };
    }

    pub fn write(self: *UDPBatch, packets: helpers.Packets, destination: io.SocketAddress) ?usize {
        if (!self.can_write or packets.len < 2) return null;
        var address: linux.sockaddr.in6 = undefined;
        const address_len = nativeAddress(&address, self.dual_stack, destination) orelse return null;
        var messages: [batch_size]linux.mmsghdr = undefined;
        var vectors: [batch_size]std.posix.iovec = undefined;
        const count = @min(packets.len, batch_size);
        for (packets[0..count], 0..) |packet, i| {
            vectors[i] = .{ .base = @constCast(packet.ptr), .len = packet.len };
            messages[i] = std.mem.zeroes(linux.mmsghdr);
            messages[i].hdr = .{ .name = @ptrCast(&address), .namelen = address_len, .iov = @ptrCast(&vectors[i]), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        }
        while (true) {
            const result = linux.sendmmsg(self.fd, &messages, @intCast(count), linux.MSG.DONTWAIT);
            switch (linux.errno(result)) {
                .SUCCESS => return result,
                .INTR => continue,
                .NOSYS, .OPNOTSUPP, .PERM => self.can_write = false,
                else => {},
            }
            return null; // Scalar I/O retains its error handling and tracing.
        }
    }

    pub fn read(self: *UDPBatch, buffers: []helpers.ReadBuffer, max_bytes: usize) ?usize {
        if (!self.can_read or buffers.len < 2) return null;
        // Full UDP storage guarantees no truncation within a batch. Smaller
        // loans use the scalar path, which discards oversized packets in place.
        for (buffers) |buffer| if (buffer.data.len < max_datagram) return null;
        var messages: [batch_size]linux.mmsghdr = undefined;
        var vectors: [batch_size]std.posix.iovec = undefined;
        var addresses: [batch_size]linux.sockaddr.in6 = undefined;
        var received: usize = 0;
        var bytes: usize = 0;
        while (received < buffers.len) {
            // Respect the byte budget even for maximum-size datagrams. Like
            // scalar reads, always permit one packet to make forward progress.
            const count = @min(buffers.len - received, batch_size, @max(1, (max_bytes -| bytes) / max_datagram));
            for (buffers[received..][0..count], 0..) |buffer, i| {
                vectors[i] = .{ .base = buffer.data.ptr, .len = max_datagram };
                messages[i] = std.mem.zeroes(linux.mmsghdr);
                messages[i].hdr = .{ .name = @ptrCast(&addresses[i]), .namelen = @sizeOf(linux.sockaddr.in6), .iov = @ptrCast(&vectors[i]), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            }
            const result = linux.recvmmsg(self.fd, &messages, @intCast(count), linux.MSG.DONTWAIT, null);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| {
                    if (err == .NOSYS or err == .OPNOTSUPP or err == .PERM) self.can_read = false;
                    return if (received != 0) received else null;
                },
            }
            for (0..result) |i| {
                const buffer = &buffers[received + i];
                buffer.size = messages[i].len;
                buffer.source = portableAddress(&addresses[i]);
                bytes += buffer.size;
            }
            received += result;
            if (result < count or bytes >= max_bytes) break;
        }
        return received;
    }

    fn nativeAddress(out: *linux.sockaddr.in6, dual_stack: bool, address: io.SocketAddress) ?u32 {
        if (address.family == 4 and !dual_stack) {
            const v4: *linux.sockaddr.in = @ptrCast(out);
            v4.* = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.address[0..4].*) };
            return @sizeOf(linux.sockaddr.in);
        }
        if (address.family != 4 and address.family != 6) return null;
        out.* = .{ .port = std.mem.nativeToBig(u16, address.port), .flowinfo = 0, .addr = address.address, .scope_id = address.scope_id };
        if (address.family == 4) out.addr = mapped_prefix ++ address.address[0..4].*;
        return @sizeOf(linux.sockaddr.in6);
    }

    fn portableAddress(address: *const linux.sockaddr.in6) io.SocketAddress {
        var result = std.mem.zeroes(io.SocketAddress);
        if (address.family == linux.AF.INET) {
            const v4: *const linux.sockaddr.in = @ptrCast(address);
            result.family = 4;
            result.port = std.mem.bigToNative(u16, v4.port);
            result.address[0..4].* = @bitCast(v4.addr);
        } else if (std.mem.eql(u8, address.addr[0..12], &mapped_prefix)) {
            result.family = 4;
            result.port = std.mem.bigToNative(u16, address.port);
            result.address[0..4].* = address.addr[12..16].*;
        } else {
            result.family = 6;
            result.port = std.mem.bigToNative(u16, address.port);
            result.address = address.addr;
            result.scope_id = address.scope_id;
        }
        return result;
    }
};
