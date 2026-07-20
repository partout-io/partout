// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const c_common = @import("../c/exports.zig").common;
const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const util = core.util;

const c = @cImport({
    @cInclude("wireguard/wireguard.h");
});

pub const Error = std.mem.Allocator.Error || error{
    BackendUnavailable,
    CannotLocateTunnelFileDescriptor,
};

pub const StartTunnel = struct {
    tun: ?net.TunWrapper = null,
    ifname: ?[]const u8 = null,

    pub fn descriptor(self: StartTunnel) ?net.FileDescriptor {
        const tun = self.tun orelse return null;
        return tun.muxDescriptor();
    }
};

pub const Backend = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        turn_on: *const fn (?*anyopaque, std.mem.Allocator, []const u8, StartTunnel) Error!i32,
        turn_off: *const fn (?*anyopaque, i32) void,
        get_config: *const fn (?*anyopaque, std.mem.Allocator, i32) Error!?[]u8,
        set_config: *const fn (?*anyopaque, std.mem.Allocator, i32, []const u8) Error!i64,
        socket_descriptors: *const fn (?*anyopaque, std.mem.Allocator, i32) Error![]net.SocketDescriptor,
        bump_sockets: *const fn (?*anyopaque, i32, bool) void,
        disable_roaming: *const fn (?*anyopaque, i32) void,
    };

    pub fn turnOn(
        self: Backend,
        allocator: std.mem.Allocator,
        settings: []const u8,
        tunnel: StartTunnel,
    ) Error!i32 {
        return self.vtable.turn_on(self.ptr, allocator, settings, tunnel);
    }

    pub fn turnOff(self: Backend, handle: i32) void {
        self.vtable.turn_off(self.ptr, handle);
    }

    pub fn getConfig(
        self: Backend,
        allocator: std.mem.Allocator,
        handle: i32,
    ) Error!?[]u8 {
        return self.vtable.get_config(self.ptr, allocator, handle);
    }

    pub fn setConfig(
        self: Backend,
        allocator: std.mem.Allocator,
        handle: i32,
        settings: []const u8,
    ) Error!i64 {
        return self.vtable.set_config(self.ptr, allocator, handle, settings);
    }

    pub fn socketDescriptors(
        self: Backend,
        allocator: std.mem.Allocator,
        handle: i32,
    ) Error![]net.SocketDescriptor {
        return self.vtable.socket_descriptors(self.ptr, allocator, handle);
    }

    pub fn bumpSockets(self: Backend, handle: i32, sync: bool) void {
        self.vtable.bump_sockets(self.ptr, handle, sync);
    }

    pub fn disableRoaming(self: Backend, handle: i32) void {
        self.vtable.disable_roaming(self.ptr, handle);
    }
};

pub fn goBackend() Backend {
    return .{ .vtable = &go_backend_vtable };
}

const go_backend_vtable = Backend.VTable{
    .turn_on = cTurnOn,
    .turn_off = cTurnOff,
    .get_config = cGetConfig,
    .set_config = cSetConfig,
    .socket_descriptors = cSocketDescriptors,
    .bump_sockets = cBumpSockets,
    .disable_roaming = cDisableRoaming,
};

fn cTurnOn(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    settings: []const u8,
    tunnel: StartTunnel,
) Error!i32 {
    if (c.pp_wg_init() != 0) return error.BackendUnavailable;

    var c_settings: util.TemporaryCString = .{};
    try c_settings.init(allocator, settings);
    defer c_settings.deinit();

    if (@import("builtin").os.tag == .windows) {
        // wireguard-go on Windows opens its own adapter by interface name;
        // Unix-family builds consume the already-created native TUN fd.
        const ifname = tunnel.ifname orelse return error.CannotLocateTunnelFileDescriptor;
        var c_ifname: util.TemporaryCString = .{};
        try c_ifname.init(allocator, ifname);
        defer c_ifname.deinit();
        return c.pp_wg_turn_on(c_settings.ptr(), c_ifname.ptr());
    }

    const fd = tunnel.descriptor() orelse return error.CannotLocateTunnelFileDescriptor;
    return c.pp_wg_turn_on(c_settings.ptr(), fd);
}

fn cTurnOff(_: ?*anyopaque, handle: i32) void {
    c.pp_wg_turn_off(handle);
}

fn cGetConfig(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    handle: i32,
) Error!?[]u8 {
    const c_config = c.pp_wg_get_config(handle) orelse return null;
    defer c_common.pp_free(c_config);
    return try allocator.dupe(u8, std.mem.span(c_config));
}

fn cSetConfig(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    handle: i32,
    settings: []const u8,
) Error!i64 {
    var c_settings: util.TemporaryCString = .{};
    try c_settings.init(allocator, settings);
    defer c_settings.deinit();
    return c.pp_wg_set_config(handle, c_settings.ptr());
}

fn cSocketDescriptors(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    handle: i32,
) Error![]net.SocketDescriptor {
    if (@hasDecl(c, "pp_wg_get_socket_v4") and @hasDecl(c, "pp_wg_get_socket_v6")) {
        // These accessors exist on Android only. The host must protect both
        // UDP sockets from being routed back into the VPN.
        var descriptors: std.ArrayList(net.SocketDescriptor) = .empty;
        errdefer descriptors.deinit(allocator);
        const v4 = c.pp_wg_get_socket_v4(handle);
        if (v4 >= 0) try descriptors.append(allocator, v4);
        const v6 = c.pp_wg_get_socket_v6(handle);
        if (v6 >= 0) try descriptors.append(allocator, v6);
        return try descriptors.toOwnedSlice(allocator);
    }
    return try allocator.alloc(net.SocketDescriptor, 0);
}

fn cBumpSockets(_: ?*anyopaque, handle: i32, sync: bool) void {
    c.pp_wg_bump_sockets(handle, sync);
}

fn cDisableRoaming(_: ?*anyopaque, handle: i32) void {
    c.pp_wg_tweak_mobile_roaming(handle);
}
