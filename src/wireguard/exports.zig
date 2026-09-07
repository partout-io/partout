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

const key_length = wireguard_c.WG_KEY_LEN;
const key_length_base64 = wireguard_c.WG_KEY_LEN_BASE64 - 1;

pub fn generatePrivateKey(
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![:0]u8 {
    var key: [key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    wireguard_c.curve25519_generate_private_key(&key);

    const key_b64: [:0]u8 = try allocator.allocSentinel(u8, key_length_base64, 0);
    wireguard_c.key_to_base64(key_b64.ptr, &key);
    return key_b64;
}

pub fn derivePublicKey(
    allocator: std.mem.Allocator,
    key_b64: [:0]const u8,
) (std.mem.Allocator.Error || error{NotBase64})![:0]u8 {
    var key: [key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    if (!wireguard_c.key_from_base64(&key, key_b64.ptr)) return error.NotBase64;

    var pub_key: [key_length]u8 = undefined;
    wireguard_c.curve25519_derive_public_key(&pub_key, &key);

    const pub_key_b64: [:0]u8 = try allocator.allocSentinel(u8, key_length_base64, 0);
    wireguard_c.key_to_base64(pub_key_b64.ptr, &pub_key);
    return pub_key_b64;
}
