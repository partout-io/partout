// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const gen = @import("api_generated.zig");
const log = @import("logging.zig");
const util = @import("util.zig");
const uuid = @import("uuid.zig");

/// Encodes a tagged module as JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeModule(
    allocator: std.mem.Allocator,
    module: gen.TaggedModule,
) gen.EncodeError![]u8 {
    return gen.encodeJsonValue(allocator, module);
}

/// Encodes a tagged module as null-terminated JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeModuleZ(
    allocator: std.mem.Allocator,
    module: gen.TaggedModule,
) gen.EncodeError![:0]u8 {
    return gen.encodeJsonValueZ(allocator, module);
}

/// Encodes a profile as JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeProfile(
    allocator: std.mem.Allocator,
    profile: gen.Profile,
) gen.EncodeError![]u8 {
    return gen.encodeJsonValue(allocator, profile);
}

/// Encodes a profile as null-terminated JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeProfileZ(
    allocator: std.mem.Allocator,
    profile: gen.Profile,
) gen.EncodeError![:0]u8 {
    return gen.encodeJsonValueZ(allocator, profile);
}

/// Finds the first active module that can establish a tunnel connection.
pub fn findActiveConnectionModule(profile: gen.Profile) ?*const gen.TaggedModule {
    for (profile.modules) |*module| {
        if (isActiveConnectionModule(profile, module)) return module;
    }
    return null;
}

/// Reports whether the profile has an active connection-building module.
pub fn hasConnection(profile: gen.Profile) bool {
    return findActiveConnectionModule(profile) != null;
}

/// Reports whether `module_id` appears in the profile active module list.
pub fn isActiveProfileModule(profile: gen.Profile, module_id: uuid.UUID) bool {
    for (profile.active_modules_ids) |active_id| {
        if (std.mem.eql(u8, active_id[0..], module_id[0..])) return true;
    }
    return false;
}

/// Logs a decoded profile using the core logging facility.
pub fn logDecodedProfile(allocator: std.mem.Allocator, profile: gen.Profile) void {
    if (!log.hasLogger()) return;

    log.write(.notice, "Decoded profile:");
    log.writef(.notice, "\tID: {s}", .{profile.id[0..]});
    log.writef(.notice, "\tName: {s}", .{profile.name});
    if (profile.behavior) |behavior| {
        const encoded = util.encodeJsonValue(allocator, behavior) catch return;
        defer allocator.free(encoded);
        log.writef(.notice, "\tBehavior: {s}", .{encoded});
    }
    log.write(.notice, "\tModules:");
    for (profile.modules) |module| {
        logProfileModule(allocator, profile, module);
    }
}

/// Returns the schema id stored in a tagged module.
///
/// Custom modules currently do not have a schema-level id, so they use the zero
/// UUID as a sentinel.
pub fn moduleId(module: *const gen.TaggedModule) uuid.UUID {
    return switch (module.*) {
        .DNS => |m| m.id,
        .HTTPProxy => |m| m.id,
        .IP => |m| m.id,
        .OnDemand => |m| m.id,
        .OpenVPN => |m| m.id,
        .WireGuard => |m| m.id,
    };
}

/// Returns the module type represented by a tagged union case.
pub fn moduleType(module: *const gen.TaggedModule) gen.ModuleType {
    return switch (module.*) {
        .DNS => .DNS,
        .HTTPProxy => .HTTPProxy,
        .IP => .IP,
        .OnDemand => .OnDemand,
        .OpenVPN => .OpenVPN,
        .WireGuard => .WireGuard,
    };
}

/// Parses a tagged module from JSON text.
pub fn parseModule(
    allocator: std.mem.Allocator,
    text: []const u8,
) gen.DecodeError!gen.TaggedModule {
    var parsed = try util.parseJsonValue(allocator, text);
    defer parsed.deinit();

    return gen.TaggedModule.parseValue(allocator, parsed.value);
}

/// Reports whether a module type can establish a tunnel connection by itself.
pub fn typeBuildsConnection(value: gen.ModuleType) bool {
    return switch (value) {
        .OpenVPN, .WireGuard => true,
        else => false,
    };
}

/// Reports whether `module` is both active in the profile and connection-capable.
fn isActiveConnectionModule(profile: gen.Profile, module: *const gen.TaggedModule) bool {
    return isActiveProfileModule(profile, moduleId(module)) and typeBuildsConnection(moduleType(module));
}

fn logProfileModule(allocator: std.mem.Allocator, profile: gen.Profile, module: gen.TaggedModule) void {
    const active_marker: u8 = if (isActiveProfileModule(profile, moduleId(&module))) '+' else '-';
    const type_name = moduleType(&module).raw();
    if (log.logsPrivateData()) {
        const encoded = util.encodeJsonValue(allocator, module) catch {
            log.writef(.notice, "\t\t{c} {s}: {s}", .{ active_marker, type_name, moduleType(&module).raw() });
            return;
        };
        defer allocator.free(encoded);
        log.writef(.notice, "\t\t{c} {s}: {s}", .{ active_marker, type_name, encoded });
        return;
    }
    log.writef(.notice, "\t\t{c} {s}: {s}", .{ active_marker, type_name, moduleType(&module).raw() });
}
