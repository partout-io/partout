// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const gen = @import("api_generated.zig");
const util = @import("util.zig");
const uuid = @import("uuid.zig");

/// Encodes a tagged module as JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeModule(
    allocator: std.mem.Allocator,
    module: *const gen.TaggedModule,
) gen.EncodeError![]u8 {
    return gen.encodeJsonValue(allocator, module);
}

/// Encodes a tagged module as null-terminated JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeModuleZ(
    allocator: std.mem.Allocator,
    module: *const gen.TaggedModule,
) gen.EncodeError![:0]u8 {
    return gen.encodeJsonValueZ(allocator, module);
}

/// Encodes a profile as JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeProfile(
    allocator: std.mem.Allocator,
    profile: *const gen.Profile,
) gen.EncodeError![]u8 {
    return gen.encodeJsonValue(allocator, profile);
}

/// Encodes a profile as null-terminated JSON.
///
/// The returned buffer is allocated with `allocator` and must be freed by the
/// caller.
pub fn encodeProfileZ(
    allocator: std.mem.Allocator,
    profile: *const gen.Profile,
) gen.EncodeError![:0]u8 {
    return gen.encodeJsonValueZ(allocator, profile);
}

/// Finds the first active module that can establish a tunnel connection.
pub fn findActiveConnectionModule(profile: *const gen.Profile) ?*const gen.TaggedModule {
    for (profile.modules) |*module| {
        if (isActiveConnectionModule(profile, module)) return module;
    }
    return null;
}

/// Reports whether the profile has an active connection-building module.
pub fn hasConnection(profile: *const gen.Profile) bool {
    return findActiveConnectionModule(profile) != null;
}

/// Reports whether `module_id` appears in the profile active module list.
pub fn isActiveProfileModule(profile: *const gen.Profile, module_id: uuid.UUID) bool {
    for (profile.active_modules_ids) |active_id| {
        if (std.mem.eql(u8, active_id[0..], module_id[0..])) return true;
    }
    return false;
}

/// Returns the schema id stored in a tagged module.
///
/// Custom modules currently do not have a schema-level id, so they use the zero
/// UUID as a sentinel.
pub fn moduleId(module: *const gen.TaggedModule) uuid.UUID {
    return switch (module.*) {
        .DNS => |*value| value.id,
        .HTTPProxy => |*value| value.id,
        .IP => |*value| value.id,
        .OnDemand => |*value| value.id,
        .OpenVPN => |*value| value.id,
        .WireGuard => |*value| value.id,
    };
}

/// Allocates a cache filename scoped to a module as `<module-id>-<filename>`.
///
/// The caller owns the returned memory.
pub fn moduleCacheFilename(
    allocator: std.mem.Allocator,
    module_id: uuid.UUID,
    filename: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{
        module_id[0..],
        filename,
    });
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
fn isActiveConnectionModule(profile: *const gen.Profile, module: *const gen.TaggedModule) bool {
    return isActiveProfileModule(profile, moduleId(module)) and typeBuildsConnection(moduleType(module));
}
