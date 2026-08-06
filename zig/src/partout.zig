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

pub const panic = std.debug.FullPanic(panicHandler);

const allocator = std.heap.c_allocator;
const identifier = "io.partout";
const version = "0.154.3";
const version_identifier: [:0]const u8 = std.fmt.comptimePrint("{s} {s}", .{ identifier, version });

// const DaemonRuntime = if (builtin.is_test) @import("testing/mock.zig").MockRuntime else abi.DaemonRuntime;
// var daemon_runtime = DaemonRuntime{};
var daemon_runtime: ?*abi.DaemonRuntime = null;
var daemon_process_lock: DaemonProcessLock = .{};

const DaemonProcessLock = struct {
    mutex: core.Mutex = .{},
    condition: core.Condition = .{},
    is_locked: bool = false,

    fn prepare(self: *DaemonProcessLock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_locked = true;
    }

    fn wait(self: *DaemonProcessLock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.is_locked) {
            self.condition.wait(&self.mutex);
        }
    }

    fn release(self: *DaemonProcessLock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_locked = false;
        self.condition.broadcast();
    }
};

/// Prints at most a 4096-char message (0-terminated).
fn panicHandler(message: []const u8, _: ?usize) noreturn {
    var buffer: [4097]u8 = undefined;
    const message_length = @min(message.len, buffer.len - 1);
    @memcpy(buffer[0..message_length], message[0..message_length]);
    buffer[message_length] = 0;
    c_common.pp_panic(buffer[0..message_length :0].ptr);
    @trap();
}

pub export fn partout_version() callconv(.c) [*:0]const u8 {
    return version_identifier.ptr;
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
    const args = args_pointer orelse return c.PartoutCompletionCodeArgs;
    var releases_bindings = true;
    defer if (releases_bindings) releaseDaemonBindings(args.bindings);
    if (daemon_runtime != null) return mapErrorToCode(error.AlreadyStarted);

    var error_info: api.JsonErrorInfo = .{};
    var options = abi.DaemonOptions.init(allocator, args.*, &error_info) catch |err| {
        if (error_info.key) |key| {
            log.writef(.fault, "Unable to parse profile: {s}, {s}", .{ @errorName(err), key });
        } else {
            log.writef(.fault, "Unable to parse profile: {s}", .{@errorName(err)});
        }
        return c.PartoutCompletionCodeArgs;
    };

    const runtime = abi.DaemonRuntime.init(allocator, options, args.bindings) catch |err| {
        options.deinit(allocator);
        return mapErrorToCode(err);
    };

    // Take ownership of the bindings now that the runtime exists
    releases_bindings = false;

    runtime.start() catch |err| {
        runtime.stop();
        runtime.destroy(allocator);
        return mapErrorToCode(err);
    };
    const is_daemon = runtime.options.is_daemon;
    if (is_daemon) daemon_process_lock.prepare();
    daemon_runtime = runtime;
    if (is_daemon) daemon_process_lock.wait();
    return c.PartoutCompletionCodeOK;
}

fn releaseDaemonBindings(bindings: ?*const c.partout_daemon_bindings) void {
    const value = bindings orelse return;
    const release = value.release orelse return;
    release(@constCast(value));
}

pub export fn partout_daemon_hold() callconv(.c) void {
    const runtime = daemon_runtime orelse return;
    runtime.hold();
}

pub export fn partout_daemon_stop() callconv(.c) void {
    const runtime = daemon_runtime orelse return;
    const is_daemon = runtime.options.is_daemon;
    runtime.stop();
    runtime.destroy(allocator);
    daemon_runtime = null;
    if (is_daemon) daemon_process_lock.release();
}

fn mapErrorToCode(err: abi.RuntimeError) c_int {
    log.writef(.err, "Unable to start daemon: {s}", .{@errorName(err)});
    return switch (err) {
        error.InvalidArgs => c.PartoutCompletionCodeArgs,
        else => c.PartoutCompletionCodeFailure,
    };
}
