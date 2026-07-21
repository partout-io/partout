// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const build_options = @import("build_options");

fn featureModule(comptime enabled: bool, comptime path: []const u8) type {
    return if (enabled) @import(path) else struct {};
}

pub const abi = @import("abi/exports.zig");
pub const abi_helpers = @import("abi/helpers.zig");
pub const abi_runtime = @import("abi/runtime.zig");
pub const core = @import("core/exports.zig");
pub const core_logging = @import("core/logging.zig");
pub const core_api = @import("core/api.zig");
pub const core_actor = @import("core/actor.zig");
pub const core_registry = @import("core/registry.zig");
pub const core_uuid = @import("core/uuid.zig");
pub const mock = @import("testing/mock.zig");
pub const net = @import("net/exports.zig");
pub const net_connection = @import("net/connection.zig");
pub const net_daemon = @import("net/daemon.zig");
pub const net_daemon_helpers = @import("net/daemon_helpers.zig");
pub const net_io = @import("net/io.zig");
pub const net_looper = @import("net/looper.zig");
pub const net_looper_queue = @import("net/looper_queue.zig");
pub const net_sandbox = @import("net/sandbox.zig");
pub const net_platform = @import("net/platform.zig");
pub const openvpn_enabled = build_options.openvpn;
pub const openvpn_exports = featureModule(openvpn_enabled, "openvpn/exports.zig");
pub const openvpn_parser = featureModule(openvpn_enabled, "openvpn/parser.zig");
pub const openvpn_serializer = featureModule(openvpn_enabled, "openvpn/serializer.zig");
pub const openvpn_tmp = featureModule(openvpn_enabled, "openvpn/tmp/exports.zig");
pub const partout = @import("partout.zig");
pub const wireguard_enabled = build_options.wireguard;
pub const wireguard_adapter = featureModule(wireguard_enabled, "wireguard/adapter.zig");
pub const wireguard_backend = featureModule(wireguard_enabled, "wireguard/backend.zig");
pub const wireguard_connection = featureModule(wireguard_enabled, "wireguard/connection.zig");
pub const wireguard_exports = featureModule(wireguard_enabled, "wireguard/exports.zig");
pub const wireguard_parser = featureModule(wireguard_enabled, "wireguard/parser.zig");
pub const wireguard_serializer = featureModule(wireguard_enabled, "wireguard/serializer.zig");
pub const wireguard_tunnel_info = featureModule(wireguard_enabled, "wireguard/tunnel_info.zig");
pub const wireguard_uapi = featureModule(wireguard_enabled, "wireguard/uapi.zig");
