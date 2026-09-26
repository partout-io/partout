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

pub const partout_c = @import("partout_c");

pub const Importer = struct {
    registry: core.Registry,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Importer {
        return .{
            .registry = try core.Registry.init(allocator, &.{
                openvpn.module_implementation,
                wireguard.module_implementation,
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

    pub fn importModuleWithContext(
        self: *const Importer,
        allocator: std.mem.Allocator,
        text: []const u8,
        context: *const api.ModuleImportContext,
        parse_error_info: ?*api.ParseErrorInfo,
    ) ImportAndEncodeError![:0]u8 {
        var module = switch (context.*) {
            .OpenVPN => |options| openvpn: {
                var parser_context: openvpn.ImportContext = .{
                    .passphrase = options.passphrase,
                };
                break :openvpn try self.registry.importModuleOfType(
                    allocator,
                    text,
                    .OpenVPN,
                    core.ImportContext.init(parse_error_info, &parser_context),
                );
            },
            .WireGuard => try self.registry.importModuleOfType(
                allocator,
                text,
                .WireGuard,
                core.ImportContext.init(parse_error_info, null),
            ),
        };
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

    pub fn exportModule(
        self: *const Importer,
        allocator: std.mem.Allocator,
        module: *const api.TaggedModule,
    ) core.SerializeError![:0]u8 {
        const text = try self.registry.serializeModule(allocator, module, null);
        const text_len = text.len;
        const terminated = allocator.realloc(text, text_len + 1) catch {
            allocator.free(text);
            return error.OutOfMemory;
        };
        terminated[text_len] = 0;
        return terminated[0..text_len :0];
    }
};

pub const BoundDaemonEvents = struct {
    binding: ?partout_c.partout_daemon_events,

    pub fn init(bindings: ?*const partout_c.partout_daemon_bindings) BoundDaemonEvents {
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

fn boundEventLastError(ptr: *anyopaque, err_pair: api.PartoutErrorPair) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const set = binding.set_last_error_code orelse return;
    const c_code = api.errorPairFormatZ(std.heap.c_allocator, err_pair) catch return;
    defer std.heap.c_allocator.free(c_code);
    set(binding.ctx, c_code.ptr);
}

fn boundEventRemoveKey(ptr: *anyopaque, key: net.DaemonEventKey) void {
    const binding = boundEventsBinding(ptr) orelse return;
    const remove = binding.remove orelse return;
    util.withCString(eventKeyString(key), remove, binding.ctx);
}

fn boundEventsBinding(ptr: *anyopaque) ?partout_c.partout_daemon_events {
    const self: *BoundDaemonEvents = @ptrCast(@alignCast(ptr));
    return self.binding;
}

// MARK: - ABI JSON

pub fn successPayloadAllocZ(
    allocator: std.mem.Allocator,
    json: [*:0]const u8,
) ?[*:0]u8 {
    const payload_json = std.mem.span(json);
    defer allocator.free(payload_json);
    return util.encodeJsonValueZ(allocator, api.ABIEnvelope{
        .payload = .{ .bytes = payload_json },
    }) catch null;
}

pub fn errorPayloadAllocZ(
    allocator: std.mem.Allocator,
    err_pair: api.PartoutErrorPair,
    parse_error_info: ?*const api.ParseErrorInfo,
) ?[*:0]u8 {
    var info = if (parse_error_info) |value| value.* else api.ParseErrorInfo{};
    info.sub_code = err_pair.sub_code;

    // No meaningful parse error information
    if (info.recognized_type == null and info.sub_code == null and
        info.name == null and info.line == null and info.arguments.len == 0)
    {
        return util.encodeJsonValueZ(allocator, api.ABIEnvelope{
            .code = err_pair.code,
        }) catch null;
    }

    // Encode info as anonymous ABIEnvelope (skip raw JSON payload)
    return util.encodeJsonValueZ(allocator, .{
        .code = err_pair.code,
        .payload = info,
    }) catch null;
}

pub fn importErrorPayloadAllocZ(
    allocator: std.mem.Allocator,
    err: ImportAndEncodeError,
    context: core.ImportContext,
) ?[*:0]u8 {
    return errorPayloadAllocZ(
        allocator,
        importErrorPair(err, context),
        context.parse_error_info,
    );
}

// MARK: - Mappings

fn eventKeyString(key: net.DaemonEventKey) [:0]const u8 {
    return switch (key) {
        .connection_status => "connectionStatus",
        .data_count => "dataCount",
        .last_error_code => "lastErrorCode",
    };
}

fn importErrorPair(err: ImportAndEncodeError, context: core.ImportContext) api.PartoutErrorPair {
    var err_pair: api.PartoutErrorPair = .{
        .code = switch (err) {
            error.OutOfMemory => .outOfMemory,
            error.IdGeneration => .unhandled,
            error.InvalidJson, error.InvalidProfile => .decoding,
            error.InvalidModel, error.Stringify => .encoding,
            error.Parsing => .parsing,
            error.UnknownImportedModule => .unknownImportedModule,
        },
    };
    const info = context.parse_error_info orelse return err_pair;
    err_pair.sub_code = info.sub_code;
    switch (err) {
        error.Parsing,
        error.InvalidJson,
        error.InvalidProfile,
        => {
            if (info.sub_code == null) return err_pair;
            const module_type = info.recognized_type orelse return err_pair;
            err_pair.code = switch (module_type) {
                .OpenVPN => .openVPN,
                .WireGuard => .wireGuard,
                else => err_pair.code,
            };
        },
        else => {},
    }
    return err_pair;
}
