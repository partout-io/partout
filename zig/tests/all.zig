// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const source = @import("source");

comptime {
    _ = @import("abi/helpers.zig");
    _ = @import("abi/importer.zig");
    _ = @import("abi/runtime.zig");
    _ = @import("core/actor.zig");
    _ = @import("core/concurrency.zig");
    _ = @import("core/logging.zig");
    _ = @import("core/api.zig");
    _ = @import("core/api_extensions.zig");
    _ = @import("core/registry.zig");
    _ = @import("core/util.zig");
    _ = @import("core/uuid.zig");
    _ = @import("net/connection.zig");
    _ = @import("net/daemon.zig");
    _ = @import("net/io.zig");
    _ = @import("net/looper.zig");
    _ = @import("net/looper_queue.zig");
    _ = @import("net/mux.zig");
    _ = @import("net/platform.zig");
    _ = @import("net/platform_dns.zig");
    if (source.openvpn_enabled) {
        _ = @import("openvpn/exports.zig");
        _ = @import("openvpn/internal/auth.zig");
        _ = @import("openvpn/internal/configuration.zig");
        _ = @import("openvpn/internal/constants.zig");
        _ = @import("openvpn/internal/control.zig");
        _ = @import("openvpn/internal/crypto.zig");
        _ = @import("openvpn/internal/data.zig");
        _ = @import("openvpn/internal/errors.zig");
        _ = @import("openvpn/internal/helpers.zig");
        _ = @import("openvpn/internal/packet.zig");
        _ = @import("openvpn/internal/processing.zig");
        _ = @import("openvpn/internal/push.zig");
        _ = @import("openvpn/internal/serialization.zig");
        _ = @import("openvpn/internal/session.zig");
        _ = @import("openvpn/internal/session_context.zig");
        _ = @import("openvpn/internal/session_negotiator.zig");
        _ = @import("openvpn/internal/settings.zig");
        _ = @import("openvpn/internal/tls.zig");
        _ = @import("openvpn/parser.zig");
        _ = @import("openvpn/serializer.zig");
    }
    if (source.wireguard_enabled) {
        _ = @import("wireguard/connection.zig");
        _ = @import("wireguard/exports.zig");
        _ = @import("wireguard/parser.zig");
        _ = @import("wireguard/serializer.zig");
    }
}
