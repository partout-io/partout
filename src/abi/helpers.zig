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
        c.PartoutCompletionCodeOK,
        json,
    );
}

pub fn errorPayloadAllocZ(
    allocator: std.mem.Allocator,
    code: api.PartoutErrorCode,
) ?[*:0]u8 {
    const payload = errorPayloadWithInfoAllocZ(
        allocator,
        code,
        null,
    );
    return wrapOwnedImportPayload(
        allocator,
        c.PartoutCompletionCodeFailure,
        payload,
    );
}

fn errorPayloadWithInfoAllocZ(
    allocator: std.mem.Allocator,
    code: api.PartoutErrorCode,
    parse_error_info: ?*const api.ParseErrorInfo,
) ?[*:0]u8 {
    const user_info: ?api.JSONValue = if (parse_error_info) |info| user_info: {
        if (info.name.len == 0 and info.details.len == 0) break :user_info null;
        const bytes = util.encodeJsonValue(allocator, info.*) catch break :user_info null;
        break :user_info .{
            .bytes = bytes,
            .owned = true,
        };
    } else null;
    defer if (user_info) |value| value.deinit(allocator);

    const payload: api.ABIErrorPayload = .{
        .code = code,
        .user_info = user_info,
    };
    return util.encodeJsonValueZ(allocator, payload) catch null;
}

pub fn importErrorPayloadAllocZ(
    allocator: std.mem.Allocator,
    err: ImportAndEncodeError,
    context: core.ImportContext,
) ?[*:0]u8 {
    const payload = errorPayloadWithInfoAllocZ(
        allocator,
        importErrorCode(err),
        context.parse_error_info,
    );
    return wrapOwnedImportPayload(
        allocator,
        c.PartoutCompletionCodeFailure,
        payload,
    );
}

fn wrapOwnedImportPayload(
    allocator: std.mem.Allocator,
    code: i32,
    c_payload: ?[*:0]const u8,
) ?[*:0]u8 {
    const payload_ptr = c_payload orelse return null;
    const payload_json = std.mem.span(payload_ptr);
    defer allocator.free(payload_json);

    const envelope: api.ABIEnvelope = .{
        .code = code,
        .payload = api.JSONValue{ .bytes = payload_json },
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
        error.PassphraseRequired => .passphraseRequired,
        error.UnknownImportedModule => .unknownImportedModule,
    };
}
