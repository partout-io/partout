// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const source = @import("source");
const c = source.abi_helpers.partout_c;
const io = source.ffi.io;
const Platform = source.net_platform.Platform;
fn setDelegate(_: ?*anyopaque, _: [*c]const c.partout_controller_delegate) callconv(.c) void {}
fn setTunnel(_: ?*anyopaque, uuid: [*c]const u8, _: [*c]const u8) callconv(.c) c.partout_tun {
    if (comptime @hasDecl(io, "pp_tun_open")) return @ptrCast(io.pp_tun_open(uuid));
    return null;
}
fn report(_: ?*anyopaque, _: [*c]const u8) callconv(.c) void {}
fn environment(_: ?*anyopaque, _: [*c]const u8, _: [*c]const u8) callconv(.c) void {}
fn clear(_: ?*anyopaque, _: bool) callconv(.c) void {}
fn configure(_: ?*anyopaque, _: [*c]const c.partout_reachability, _: [*c]const c.partout_socket_descriptor, _: usize) callconv(.c) bool {
    return true;
}
pub const functions: c.partout_controller_functions = .{
    .set_delegate = setDelegate,
    .set_tunnel = setTunnel,
    .report_snapshot = report,
    .set_environment_value = environment,
    .clear_tunnel = clear,
    .cancel_tunnel = report,
    .configure_sockets = configure,
};
pub const bindings: c.partout_daemon_bindings = .{ .controller_functions = functions };
pub fn nativeFunctions() io.pp_tun_ctrl_fnt {
    return .{ .set_delegate = @ptrCast(functions.set_delegate), .set_tunnel = @ptrCast(functions.set_tunnel), .report_snapshot = @ptrCast(functions.report_snapshot), .set_environment_value = @ptrCast(functions.set_environment_value), .clear_tunnel = @ptrCast(functions.clear_tunnel), .cancel_tunnel = @ptrCast(functions.cancel_tunnel) };
}
pub fn initPlatform(options: struct {
    ref: ?*anyopaque = null,
    fnt: ?Platform.FunctionTable = null,
    socket_configurator: ?io.pp_socket_configurator = null,
    socket_buf_size: c_int = 1024 * 1024,
}) !Platform {
    return Platform.init(.{ .ref = options.ref, .fnt = options.fnt orelse nativeFunctions(), .socket_configurator = options.socket_configurator orelse .{ .ctx = options.ref, .configure = @ptrCast(functions.configure_sockets) }, .socket_buf_size = options.socket_buf_size });
}
