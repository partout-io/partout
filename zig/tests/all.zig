// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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
    _ = @import("net/platform.zig");
    _ = @import("openvpn/exports.zig");
    _ = @import("openvpn/parser.zig");
    _ = @import("wireguard/connection.zig");
    _ = @import("wireguard/exports.zig");
    _ = @import("wireguard/parser.zig");
    _ = @import("wireguard/serializer.zig");
}
