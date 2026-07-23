// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const openvpn = @import("../openvpn/exports.zig");
const wireguard = @import("../wireguard/exports.zig");
const api = core.api;
const util = core.util;

const ImportAndEncodeError = core.ImportError || api.EncodeError;

pub const c = @cImport({
    @cInclude("partout.h");
});

pub const Importer = struct {
    registry: core.Registry,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Importer {
        return .{
            .registry = try core.Registry.init(allocator, &.{
                openvpn.impl.module,
                wireguard.impl.module,
            }),
        };
    }

    pub fn deinit(self: *Importer, allocator: std.mem.Allocator) void {
        self.registry.deinit(allocator);
    }

    pub fn importModule(
        self: *const Importer,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ImportAndEncodeError![:0]u8 {
        var module = try self.registry.importModule(allocator, text, null);
        defer module.deinit(allocator);
        return api.encodeModuleZ(allocator, &module);
    }

    pub fn importProfile(
        self: *const Importer,
        allocator: std.mem.Allocator,
        text: []const u8,
        name: ?[]const u8,
    ) ImportAndEncodeError![:0]u8 {
        var profile = try self.registry.importProfile(allocator, text, name);
        defer profile.deinit(allocator);
        return api.encodeProfileZ(allocator, &profile);
    }
};

pub const BoundDaemonEvents = struct {
    binding: ?c.partout_daemon_events,

    pub fn init(bindings: ?*const c.partout_daemon_bindings) BoundDaemonEvents {
        return .{
            .binding = if (bindings) |value| value.*.events else null,
        };
    }

    pub fn interface(self: *BoundDaemonEvents) ?net.Connection.Events {
        if (self.binding == null) return null;
        return .{
            .ctx = self,
            .status = boundEventStatus,
            .last_error = boundEventLastError,
            .data_count = boundEventDataCount,
            .remove_key = boundEventRemoveKey,
        };
    }
};

fn boundEventStatus(ptr: *anyopaque, status: api.ConnectionStatus) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const set = binding.set_connection_status orelse return;
    util.withCString(status.raw(), set, binding.ctx);
}

fn boundEventDataCount(ptr: *anyopaque, data_count: api.DataCount) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const set = binding.set_data_count orelse return;
    set(binding.ctx, data_count.received, data_count.sent);
}

fn boundEventLastError(ptr: *anyopaque, code: api.PartoutErrorCode) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const set = binding.set_last_error_code orelse return;
    util.withCString(code.raw(), set, binding.ctx);
}

fn boundEventRemoveKey(ptr: *anyopaque, key: net.Connection.EventKey) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const remove = binding.remove orelse return;
    util.withCString(eventKeyString(key), remove, binding.ctx);
}

fn boundEventsBinding(ptr: *anyopaque) ?c.partout_daemon_events {
    const self: *BoundDaemonEvents = @ptrCast(@alignCast(ptr));
    return self.binding;
}

fn eventKeyString(key: net.Connection.EventKey) []const u8 {
    return switch (key) {
        .connection_status => "connectionStatus",
        .data_count => "dataCount",
        .last_error_code => "lastErrorCode",
    };
}

pub fn errorPayloadAllocZ(
    allocator: std.mem.Allocator,
    err: anyerror,
) ?[*:0]u8 {
    const code = api.codeForError(err);
    const payload: api.ABIErrorPayload = .{
        .code = code,
        .user_info = null,
    };
    return util.encodeJsonValueZ(allocator, payload) catch null;
}
