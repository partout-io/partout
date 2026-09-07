// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! The WireGuard protocol.
//!
//! This module bridges to the official WireGuard implementation provided by
//! [WireGuardGo][dep-wireguard-go].
//!
//! [dep-wireguard-go]: https://github.com/wireguard/wireguard-go

const std = @import("std");
const build_options = @import("build_options");

const backend = @import("internal/backend.zig");
const connection = @import("connection.zig");
const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const parser = @import("parser.zig");
const serializer = @import("serializer.zig");
const wireguard_c = @import("wireguard_c");

const ModuleType = core.api.ModuleType;

pub const module_implementation: core.ModuleImplementation = .{
    .ptr = null,
    .vtable = &module_vtable,
};
const module_vtable: core.ModuleImplementation.VTable = .{
    .module_type = moduleType,
    .import_module = parser.importModule,
    .serialize_module = serializer.serializeModule,
};

pub const ConnectionContext = connection.ConnectionContext;
pub const go_backend = backend.goBackend();
pub const connection_vtable: net.ConnectionImplementation.VTable = .{
    .module_type = moduleType,
    .create_connection = connection.createConnection,
};

fn moduleType(_: ?*const anyopaque) ModuleType {
    return .WireGuard;
}

const key_length = 32;
const key_length_base64 = 45;

pub fn generatePrivateKey(
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![:0]u8 {
    const key: [:0]u8 = try allocator.allocSentinel(u8, key_length, 0);
    defer allocator.free(key);
    wireguard_c.curve25519_generate_private_key(key.ptr);

    const key_b64: [:0]u8 = try allocator.allocSentinel(u8, key_length_base64, 0);
    wireguard_c.key_to_base64(key_b64.ptr, key.ptr);
    return key_b64;
}

pub fn derivePublicKey(
    allocator: std.mem.Allocator,
    key_b64: [:0]const u8,
) (std.mem.Allocator.Error || error{NotBase64})![:0]u8 {
    const key: [:0]u8 = try allocator.allocSentinel(u8, key_length, 0);
    defer allocator.free(key);
    if (!wireguard_c.key_from_base64(key.ptr, key_b64.ptr)) return error.NotBase64;

    // Can do in place, private key is copied to local buffer (see x25519.c).
    // wireguard_c.curve25519_derive_public_key(key.ptr, key.ptr);
    const pub_key: [:0]u8 = try allocator.allocSentinel(u8, key_length, 0);
    defer allocator.free(pub_key);
    wireguard_c.curve25519_derive_public_key(pub_key.ptr, key.ptr);

    const pub_key_b64: [:0]u8 = try allocator.allocSentinel(u8, key_length_base64, 0);
    wireguard_c.key_to_base64(pub_key_b64.ptr, pub_key.ptr);
    return pub_key_b64;
}
