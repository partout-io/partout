// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const test_abi_helpers = @import("abi/helpers.zig");
const test_abi_importer = @import("abi/importer.zig");
const test_abi_runtime = @import("abi/runtime.zig");
const test_c_exports = @import("c/exports.zig");
const test_c_socket = @import("c/socket.zig");
const test_c_crypto_aead = @import("c/crypto/aead.zig");
const test_c_crypto_cbc = @import("c/crypto/cbc.zig");
const test_c_crypto_ctr = @import("c/crypto/ctr.zig");
const test_core_actor = @import("core/actor.zig");
const test_core_concurrency = @import("core/concurrency.zig");
const test_core_logging = @import("core/logging.zig");
const test_core_api = @import("core/api.zig");
const test_core_api_extensions = @import("core/api_extensions.zig");
const test_core_registry = @import("core/registry.zig");
const test_core_util = @import("core/util.zig");
const test_core_uuid = @import("core/uuid.zig");
const test_net_connection = @import("net/connection.zig");
const test_net_daemon = @import("net/daemon.zig");
const test_net_daemon_v2 = @import("net/daemon_v2.zig");
const test_net_io = @import("net/io.zig");
const test_net_io_common = @import("net/io_common.zig");
const test_net_io_posix = @import("net/io_posix.zig");
const test_net_socket_datagram = @import("net/socket_datagram.zig");
const test_net_looper_legacy = @import("net/looper_legacy.zig");
const test_net_looper_v2 = @import("net/looper_v2.zig");
const test_net_looper_io = @import("net/looper_io.zig");
const test_net_looper_helpers = @import("net/looper_helpers.zig");
const test_net_mux = @import("net/mux.zig");
const test_net_platform = @import("net/platform.zig");
const test_net_resolver = @import("net/resolver.zig");
const test_openvpn_configuration = @import("openvpn/configuration.zig");
const test_openvpn_connection = @import("openvpn/connection.zig");
const test_openvpn_exports = @import("openvpn/exports.zig");
const test_openvpn_internal_auth = @import("openvpn/internal/auth.zig");
const test_openvpn_internal_configuration = @import("openvpn/internal/configuration.zig");
const test_openvpn_internal_constants = @import("openvpn/internal/constants.zig");
const test_openvpn_internal_control = @import("openvpn/internal/control.zig");
const test_openvpn_internal_crypto = @import("openvpn/internal/crypto.zig");
const test_openvpn_internal_data = @import("openvpn/internal/data.zig");
const test_openvpn_internal_helpers = @import("openvpn/internal/helpers.zig");
const test_openvpn_internal_keys = @import("openvpn/internal/keys.zig");
const test_openvpn_internal_logging = @import("openvpn/internal/logging.zig");
const test_openvpn_internal_packet = @import("openvpn/internal/packet.zig");
const test_openvpn_internal_processing = @import("openvpn/internal/processing.zig");
const test_openvpn_internal_push = @import("openvpn/internal/push.zig");
const test_openvpn_internal_serialization = @import("openvpn/internal/serialization.zig");
const test_openvpn_internal_session_legacy = @import("openvpn/internal/session_legacy.zig");
const test_openvpn_internal_session_v2 = @import("openvpn/internal/session_v2.zig");
const test_openvpn_internal_session_context = @import("openvpn/internal/session_context.zig");
const test_openvpn_internal_session_negotiator = @import("openvpn/internal/session_negotiator.zig");
const test_openvpn_internal_settings = @import("openvpn/internal/settings.zig");
const test_openvpn_internal_tls = @import("openvpn/internal/tls.zig");
const test_openvpn_parser = @import("openvpn/parser.zig");
const test_openvpn_serializer = @import("openvpn/serializer.zig");
const test_wireguard_connection = @import("wireguard/connection.zig");
const test_wireguard_connection_v2 = @import("wireguard/connection_v2.zig");
const test_wireguard_passive_io = @import("wireguard/passive_io.zig");
const test_wireguard_exports = @import("wireguard/exports.zig");
const test_wireguard_parser = @import("wireguard/parser.zig");
const test_wireguard_serializer = @import("wireguard/serializer.zig");
const source = @import("source");
const crypto_c = source.ffi.crypto;

comptime {
    _ = test_abi_helpers;
    _ = test_abi_importer;
    _ = test_abi_runtime;
    _ = test_c_exports;
    _ = test_c_socket;
    if (@hasDecl(crypto_c, "PARTOUT_CRYPTO_OPENSSL") or
        @hasDecl(crypto_c, "PARTOUT_CRYPTO_MBEDTLS"))
    {
        _ = test_c_crypto_aead;
        _ = test_c_crypto_cbc;
        _ = test_c_crypto_ctr;
    }
    _ = test_core_actor;
    _ = test_core_concurrency;
    _ = test_core_logging;
    _ = test_core_api;
    _ = test_core_api_extensions;
    _ = test_core_registry;
    _ = test_core_util;
    _ = test_core_uuid;
    _ = test_net_connection;
    if (!source.runtime_policy.v2_only) {
        _ = test_net_daemon;
    }
    _ = test_net_daemon_v2;
    _ = test_net_io;
    _ = test_net_io_common;
    if (builtin.os.tag != .windows) {
        _ = test_net_io_posix;
        _ = test_net_socket_datagram;
    }
    if (!source.runtime_policy.v2_only) {
        _ = test_net_looper_legacy;
    }
    _ = test_net_looper_v2;
    _ = test_net_looper_io;
    _ = test_net_looper_helpers;
    _ = test_net_mux;
    _ = test_net_platform;
    _ = test_net_resolver;
    if (source.openvpn_enabled) {
        _ = test_openvpn_configuration;
        _ = test_openvpn_connection;
        _ = test_openvpn_exports;
        _ = test_openvpn_internal_auth;
        _ = test_openvpn_internal_configuration;
        _ = test_openvpn_internal_constants;
        _ = test_openvpn_internal_control;
        _ = test_openvpn_internal_crypto;
        _ = test_openvpn_internal_data;
        _ = test_openvpn_internal_helpers;
        _ = test_openvpn_internal_keys;
        _ = test_openvpn_internal_logging;
        _ = test_openvpn_internal_packet;
        _ = test_openvpn_internal_processing;
        _ = test_openvpn_internal_push;
        _ = test_openvpn_internal_serialization;
        if (!source.runtime_policy.v2_only) {
            _ = test_openvpn_internal_session_legacy;
        }
        _ = test_openvpn_internal_session_v2;
        _ = test_openvpn_internal_session_context;
        _ = test_openvpn_internal_session_negotiator;
        _ = test_openvpn_internal_settings;
        _ = test_openvpn_internal_tls;
        _ = test_openvpn_parser;
        _ = test_openvpn_serializer;
    }
    if (source.wireguard_enabled) {
        _ = test_wireguard_connection;
        _ = test_wireguard_connection_v2;
        _ = test_wireguard_passive_io;
        _ = test_wireguard_exports;
        _ = test_wireguard_parser;
        _ = test_wireguard_serializer;
    }
}
