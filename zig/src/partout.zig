// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Partout provides a framework to build network profiles in a cross-platform
//! and implementation-agnostic fashion. Your application should be split into a
//! main app, acting as a controller, and a tunnel daemon, that performs the
//! low-level operations that modify the device network settings. The way the app
//! and the daemon speak to each other, and how the network configurations are
//! committed and maintained, are taken care of by Partout.

const std = @import("std");
const builtin = @import("builtin");

const abi = @import("abi/exports.zig");
const c_mod = @import("c/exports.zig");
const core = @import("core/exports.zig");
const api = core.api;
const c = abi.c;
const c_common = c_mod.common;
const log = core.logging;
const util = core.util;

const allocator = std.heap.c_allocator;
const identifier = "io.partout";
const version = "0.151.0";
const version_identifier: [*:0]const u8 = std.fmt.comptimePrint("{s} {s}", .{ identifier, version });

// const DaemonRuntime = if (builtin.is_test) @import("testing/mock.zig").MockRuntime else abi.DaemonRuntime;
// var daemon_runtime = DaemonRuntime{};
var daemon_runtime: ?*abi.DaemonRuntime = null;

pub export fn partout_version() callconv(.c) [*:0]const u8 {
    return version_identifier;
}

pub export fn partout_init(args_pointer: ?*const c.partout_init_args) callconv(.c) void {
    const args = args_pointer orelse return;
    log.init(args.logs_private_data, args.logger);
}

pub export fn partout_readfile(
    rel_path: ?[*:0]const u8,
    parent: ?[*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const path = rel_path orelse return null;
    return c_common.pp_file_read(path, parent);
}

pub export fn partout_import_profile(
    c_text: ?[*:0]const u8,
    c_name: ?[*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const text_ptr = c_text orelse return null;

    var importer = abi.Importer.init(allocator) catch return abi.errorPayloadAllocZ(allocator, error.OutOfMemory);
    defer importer.deinit(allocator);

    const profile_json = importer.importProfile(
        allocator,
        util.borrowedCString(text_ptr),
        if (c_name) |name| util.borrowedCString(name) else null,
    ) catch |err| return abi.errorPayloadAllocZ(allocator, err);
    return profile_json.ptr;
}

pub export fn partout_import_module(
    c_text: ?[*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const text_ptr = c_text orelse return null;

    var importer = abi.Importer.init(allocator) catch return abi.errorPayloadAllocZ(allocator, error.OutOfMemory);
    defer importer.deinit(allocator);

    const module_json = importer.importModule(
        allocator,
        util.borrowedCString(text_ptr),
    ) catch |err| return abi.errorPayloadAllocZ(allocator, err);
    return module_json.ptr;
}

pub export fn partout_daemon_start(
    args_pointer: ?*const c.partout_daemon_start_args,
) callconv(.c) c_int {
    if (daemon_runtime != null) return mapErrorToCode(error.AlreadyStarted);

    const args = args_pointer orelse return c.PartoutCompletionCodeArgs;
    var error_info: api.JsonErrorInfo = .{};
    var options = abi.DaemonOptions.init(allocator, args.*, &error_info) catch |err| {
        if (err == error.InvalidProfile) {
            if (error_info.key) |key| {
                log.writef(.fault, "Unable to parse profile: {s}", .{key});
            }
        }
        return c.PartoutCompletionCodeArgs;
    };

    const runtime = abi.DaemonRuntime.init(allocator, options, args.bindings) catch |err| {
        options.deinit(allocator);
        return mapErrorToCode(err);
    };
    errdefer runtime.deinit(allocator);

    runtime.start(allocator) catch |err| return mapErrorToCode(err);
    daemon_runtime = runtime;
    return c.PartoutCompletionCodeOK;
}

pub export fn partout_daemon_hold() callconv(.c) void {
    const runtime = daemon_runtime orelse return;
    runtime.hold();
}

pub export fn partout_daemon_stop() callconv(.c) void {
    const runtime = daemon_runtime orelse return;
    runtime.stop();
    runtime.deinit(allocator);
    daemon_runtime = null;
}

fn mapErrorToCode(err: abi.RuntimeError) c_int {
    log.writef(.err, "Unable to start daemon: {}", .{err});
    return switch (err) {
        error.InvalidArgs => c.PartoutCompletionCodeArgs,
        else => c.PartoutCompletionCodeFailure,
    };
}
