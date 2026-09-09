// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

//! Nonblocking WinRT sockets. Link the portable WinRT bridge when using this
//! wrapper. The caller serializes operations on a stable wrapper address.
//! The bridge initializes WinRT per thread. Async completions signal a Windows
//! event consumed by the existing mux; the handle is borrowed until cleanup.
const std = @import("std");
const io = @import("io_common.zig");
const c = io.io_c;

pub const SocketWrapper = struct {
    pub const enabled = @import("build_options").winrt;
    socket: c.pp_winrt_socket_ref,
    options: io.SocketOptions,
    owner_allocator: ?std.mem.Allocator = null,
    last_error: c_int = 0,

    pub fn init(allocator: std.mem.Allocator, options: io.SocketOptions) !SocketWrapper {
        const host = try allocator.dupeZ(u8, options.endpoint.address);
        defer allocator.free(host);
        var code: i32 = 0;
        var reachability = options.reachability;
        const socket = c.pp_winrt_socket_open(
            host.ptr,
            options.endpoint.proto.port,
            if (options.endpoint.plainSocketType() == .tcp) 1 else 0,
            options.timeout_ms,
            @intCast(options.buf_size),
            &code,
            if (reachability) |*value| value else null,
            options.configure,
            options.configure_ctx,
        ) orelse return error.LibcFailure;
        return .{
            .socket = socket,
            .options = options,
        };
    }

    pub fn create(allocator: std.mem.Allocator, options: io.SocketOptions) !*SocketWrapper {
        const self = try allocator.create(SocketWrapper);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, options);
        self.owner_allocator = allocator;
        return self;
    }

    /// WouldBlock while connecting; later also observes asynchronous write errors.
    pub fn poll(self: *SocketWrapper) io.Error!void {
        const socket = self.socket orelse return error.EndOfStream;
        _ = try self.mapResult(c.pp_winrt_socket_poll(socket));
    }

    pub fn read(self: *SocketWrapper, buf: []u8) io.Error!?usize {
        const socket = self.socket orelse return error.EndOfStream;
        const count = try self.mapResult(c.pp_winrt_socket_read(socket, buf.ptr, buf.len));
        if (count == 0) {
            if (self.options.closesOnEmptyRead()) return error.EndOfStream;
            return null;
        }
        return count;
    }

    /// Success means a copy was accepted by the asynchronous writer.
    pub fn write(self: *SocketWrapper, data: []const u8, offset: usize) io.Error!usize {
        const socket = self.socket orelse return error.EndOfStream;
        if (offset > data.len) return error.LibcFailure;
        const remaining = data[offset..];
        return self.mapResult(c.pp_winrt_socket_write(socket, remaining.ptr, remaining.len));
    }

    pub fn cleanup(self: *SocketWrapper) void {
        if (self.socket) |socket| c.pp_winrt_socket_close(socket);
        self.socket = null;
    }

    pub fn deinit(self: *SocketWrapper) void {
        self.cleanup();
    }

    pub fn lastErrorCode(self: *const SocketWrapper) c_int {
        return self.last_error;
    }

    pub fn nativeIO(self: *SocketWrapper) io.IOInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn muxDescriptor(self: *const SocketWrapper) ?io.FileDescriptor {
        const socket = self.socket orelse return null;
        return c.pp_winrt_socket_watch_handle(socket);
    }

    fn mapResult(self: *SocketWrapper, result: c_int) io.Error!usize {
        if (result == c.PPWinRTWouldBlock) return error.WouldBlock;
        if (result < 0) {
            self.last_error = c.pp_winrt_socket_error(self.socket.?);
            return error.LibcFailure;
        }
        return @intCast(result);
    }

    fn cast(ptr: *anyopaque) *SocketWrapper {
        return @ptrCast(@alignCast(ptr));
    }
    fn readIO(ptr: *anyopaque, buf: []u8) io.Error!?usize {
        return cast(ptr).read(buf);
    }
    fn writeIO(ptr: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        return cast(ptr).write(data, offset);
    }
    fn cleanupIO(ptr: *anyopaque) void {
        const self = cast(ptr);
        const allocator = self.owner_allocator;
        self.cleanup();
        if (allocator) |owner| owner.destroy(self);
    }
    fn lastErrorIO(ptr: *anyopaque) c_int {
        return cast(ptr).lastErrorCode();
    }
    fn setEventMask(ptr: *anyopaque, readable: bool, writable: bool) io.Error!void {
        const self = cast(ptr);
        const socket = self.socket orelse return error.EndOfStream;
        _ = try self.mapResult(c.pp_winrt_socket_set_event_mask(socket, @intFromBool(readable), @intFromBool(writable)));
    }
    fn resetEvents(ptr: *anyopaque) io.Error!void {
        const self = cast(ptr);
        const socket = self.socket orelse return error.EndOfStream;
        _ = try self.mapResult(c.pp_winrt_socket_reset_events(socket));
    }
    const vtable: io.IOInterface.VTable = .{
        .set_event_mask = setEventMask,
        .reset_events = resetEvents,
        .read = readIO,
        .write = writeIO,
        .cleanup = cleanupIO,
        .last_error_code = lastErrorIO,
    };
};

// FIXME: ###, Windows TunWrapper
/// VpnChannel owns the Windows tunnel. Packet I/O is not connected to the
/// Zig looper yet, so this wrapper exposes no descriptor or POSIX TUN calls.
pub const TunWrapper = struct {
    pub fn init(_: c.pp_tun) TunWrapper {
        return .{};
    }

    pub fn deinit(self: *TunWrapper) void {
        self.cleanup();
    }

    pub fn cleanup(_: *TunWrapper) void {}

    pub fn muxDescriptor(_: TunWrapper) ?io.FileDescriptor {
        return null;
    }

    pub fn name(_: TunWrapper) ?[]const u8 {
        return null;
    }

    pub fn nativeIO(self: *TunWrapper) io.IOInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setEventMask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn resetEvents(_: *anyopaque) io.Error!void {}
    fn read(_: *anyopaque, _: []u8) io.Error!?usize {
        return error.EndOfStream;
    }
    fn write(_: *anyopaque, _: []const u8, _: usize) io.Error!usize {
        return error.EndOfStream;
    }
    fn cleanupIO(_: *anyopaque) void {}
    fn lastErrorCode(_: *anyopaque) c_int {
        return 0;
    }

    const vtable: io.IOInterface.VTable = .{
        .set_event_mask = setEventMask,
        .reset_events = resetEvents,
        .read = read,
        .write = write,
        .cleanup = cleanupIO,
        .last_error_code = lastErrorCode,
    };
};
