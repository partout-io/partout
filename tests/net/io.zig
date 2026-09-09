// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core.api;
const io = @import("source").net_io;
const io_c = io.io_c;

const mapReadResult = io.testing.mapReadResult;
const mapWriteResult = io.testing.mapWriteResult;
const reachabilityNone = io.testing.reachabilityNone;

test "Windows tunnel wrapper has no POSIX device or packet IO" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tun = io.TunWrapper.init(null);
    defer tun.deinit();
    try std.testing.expect(tun.muxDescriptor() == null);
    try std.testing.expect(tun.name() == null);
    const native = tun.nativeIO();
    var bytes: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, native.read(&bytes));
    try std.testing.expectError(error.EndOfStream, native.write(&bytes, 0));
    native.cleanup();
    native.cleanup();
}

test "WinRT wrapper rejects nonpositive buffer sizes before opening a socket" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    const Wrapper = @import("source").net.SocketWrapper;
    if (comptime !Wrapper.enabled) return error.SkipZigTest;
    var options: io.SocketOptions = .{
        .endpoint = .{
            .address = "127.0.0.1",
            .proto = api.EndpointProtocol.init(.udp, 1194),
        },
        .timeout_ms = 0,
        .buf_size = 0,
    };
    for ([_]c_int{ 0, -1 }) |size| {
        options.buf_size = size;
        try std.testing.expectError(error.InvalidArgs, Wrapper.create(std.testing.allocator, options));
    }
}

test "WinRT wrapper exposes nonblocking IO and idempotent cleanup" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    const Wrapper = @import("source").net.SocketWrapper;
    if (comptime !Wrapper.enabled) return error.SkipZigTest;
    // Exercise the ABI-facing function bodies without requiring WinRT setup
    // on the Zig test runner. Native loopback coverage lives in tests/c/portable.
    std.testing.refAllDecls(Wrapper);
    var wrapper: Wrapper = .{
        .socket = null,
        .options = .{
            .endpoint = .{
                .address = "127.0.0.1",
                .proto = api.EndpointProtocol.init(.udp, 1194),
            },
            .timeout_ms = 0,
            .buf_size = 1024,
        },
    };
    const native = wrapper.nativeIO();
    var bytes: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, native.read(&bytes));
    try std.testing.expectError(error.EndOfStream, native.write(&bytes, 0));
    try std.testing.expectError(error.EndOfStream, native.setEventMask(true, false));
    try std.testing.expectEqual(@as(?io.FileDescriptor, null), wrapper.muxDescriptor());
    native.cleanup();
    native.cleanup();
}

test "maps native socket read results" {
    try std.testing.expectError(error.WouldBlock, mapReadResult(.link, io_c.PPIOErrorWouldBlock, false));
    try std.testing.expectEqual(@as(?usize, null), try mapReadResult(.link, 0, false));
    try std.testing.expectError(error.EndOfStream, mapReadResult(.link, 0, true));
    try std.testing.expectEqual(@as(?usize, 42), try mapReadResult(.link, 42, true));
}

test "maps native write backpressure results" {
    try std.testing.expectError(error.WouldBlock, mapWriteResult(.link, io_c.PPIOErrorWouldBlock, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.link, io_c.PPIOErrorNoBufs, false));
    try std.testing.expectError(error.LibcFailure, mapWriteResult(.link, io_c.PPIOErrorNoSpace, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.tun, io_c.PPIOErrorNoSpace, true));
    try std.testing.expectEqual(@as(usize, 7), try mapWriteResult(.link, 7, false));
}

test "constructs empty reachability" {
    const reachability = reachabilityNone();
    try std.testing.expect(!reachability.reachable);
}

test "socket wrapper reports an invalid remote address" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const wrapper = io.SocketWrapper{
        .socket = null,
        .options = .{
            .endpoint = .{
                .address = " \t",
                .proto = api.EndpointProtocol.init(.udp, 1194),
            },
            .timeout_ms = 0,
            .buf_size = 0,
        },
        .closes_on_empty_read = false,
    };

    try std.testing.expect(wrapper.remoteAddress() == null);
}
