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

pub const ImportAndEncodeError = core.ImportError || api.EncodeError;

pub const c = @cImport({
    @cInclude("c/android_import_compat.h");
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

    pub fn deinit(self: *const Importer, allocator: std.mem.Allocator) void {
        self.registry.deinit(allocator);
    }

    pub fn importModule(
        self: *const Importer,
        allocator: std.mem.Allocator,
        text: []const u8,
        context: core.ImportContext,
    ) ImportAndEncodeError![:0]u8 {
        var module = try self.registry.importModule(allocator, text, context);
        defer module.deinit(allocator);
        return api.encodeModuleZ(allocator, &module);
    }

    pub fn importProfile(
        self: *const Importer,
        allocator: std.mem.Allocator,
        text: []const u8,
        name: ?[]const u8,
        context: core.ImportContext,
    ) ImportAndEncodeError![:0]u8 {
        var profile = try self.registry.importProfile(allocator, text, name, context);
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

    pub fn interface(self: *BoundDaemonEvents) ?net.DaemonEvents {
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

fn boundEventRemoveKey(ptr: *anyopaque, key: net.DaemonEventKey) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const remove = binding.remove orelse return;
    util.withCString(eventKeyString(key), remove, binding.ctx);
}

fn boundEventsBinding(ptr: *anyopaque) ?c.partout_daemon_events {
    const self: *BoundDaemonEvents = @ptrCast(@alignCast(ptr));
    return self.binding;
}

// MARK: - ABI JSON

pub fn successPayloadAllocZ(
    allocator: std.mem.Allocator,
    json: [*:0]const u8,
) ?[*:0]u8 {
    return wrapOwnedImportPayload(
        allocator,
        null,
        json,
    );
}

pub fn errorPayloadAllocZ(
    allocator: std.mem.Allocator,
    code: api.PartoutErrorCode,
) ?[*:0]u8 {
    return wrapOwnedImportPayload(
        allocator,
        code,
        null,
    );
}

fn errorUserInfoAllocZ(
    allocator: std.mem.Allocator,
    parse_error_info: ?*const api.ParseErrorInfo,
) ?[*:0]u8 {
    const info = parse_error_info orelse return null;
    if (info.recognized_type == null and info.sub_code == null and info.name == null and info.line == null and info.arguments.len == 0) return null;
    return util.encodeJsonValueZ(allocator, info.*) catch null;
}

pub fn importErrorPayloadAllocZ(
    allocator: std.mem.Allocator,
    err: ImportAndEncodeError,
    context: core.ImportContext,
) ?[*:0]u8 {
    const code = importErrorCode(err);
    const user_info = errorUserInfoAllocZ(allocator, context.parse_error_info);
    return wrapOwnedImportPayload(
        allocator,
        code,
        user_info,
    );
}

fn wrapOwnedImportPayload(
    allocator: std.mem.Allocator,
    code: ?api.PartoutErrorCode,
    c_payload: ?[*:0]const u8,
) ?[*:0]u8 {
    const payload_json = if (c_payload) |payload_ptr| std.mem.span(payload_ptr) else null;
    defer if (payload_json) |bytes| allocator.free(bytes);

    const envelope: api.ABIEnvelope = .{
        .code = code,
        .payload = if (payload_json) |bytes| api.JSONValue{ .bytes = bytes } else null,
    };
    return util.encodeJsonValueZ(allocator, envelope) catch null;
}

// MARK: - Mappings

fn eventKeyString(key: net.DaemonEventKey) [:0]const u8 {
    return switch (key) {
        .connection_status => "connectionStatus",
        .data_count => "dataCount",
        .last_error_code => "lastErrorCode",
    };
}

fn importErrorCode(err: ImportAndEncodeError) api.PartoutErrorCode {
    return switch (err) {
        error.OutOfMemory => .outOfMemory,
        error.IdGeneration => .unhandled,
        error.InvalidJson, error.InvalidProfile => .decoding,
        error.InvalidModel, error.Stringify => .encoding,
        error.Parsing => .parsing,
        error.UnknownImportedModule => .unknownImportedModule,
    };
}
