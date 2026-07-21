// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const build_options = @import("build_options");

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
pub const openvpn_exports = if (openvpn_enabled) @import("openvpn/exports.zig") else struct {};
pub const openvpn_parser = if (openvpn_enabled) @import("openvpn/parser.zig") else struct {};
pub const openvpn_serializer = if (openvpn_enabled) @import("openvpn/serializer.zig") else struct {};
pub const openvpn_internal = if (openvpn_enabled) @import("openvpn/internal/exports.zig") else struct {};
pub const partout = @import("partout.zig");
pub const wireguard_enabled = build_options.wireguard;
pub const wireguard_adapter = if (wireguard_enabled) @import("wireguard/adapter.zig") else struct {};
pub const wireguard_backend = if (wireguard_enabled) @import("wireguard/backend.zig") else struct {};
pub const wireguard_connection = if (wireguard_enabled) @import("wireguard/connection.zig") else struct {};
pub const wireguard_exports = if (wireguard_enabled) @import("wireguard/exports.zig") else struct {};
pub const wireguard_parser = if (wireguard_enabled) @import("wireguard/parser.zig") else struct {};
pub const wireguard_serializer = if (wireguard_enabled) @import("wireguard/serializer.zig") else struct {};
pub const wireguard_tunnel_info = if (wireguard_enabled) @import("wireguard/tunnel_info.zig") else struct {};
pub const wireguard_uapi = if (wireguard_enabled) @import("wireguard/uapi.zig") else struct {};
