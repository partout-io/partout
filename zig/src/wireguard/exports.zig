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

const backend = @import("backend.zig");
const connection = @import("connection.zig");
const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const parser = @import("parser.zig");
const proto = @import("../proto/exports.zig");
const serializer = @import("serializer.zig");

const ModuleType = core.api.ModuleType;

pub const impl: proto.ModuleExports = .{
    .module = .{
        .ptr = null,
        .vtable = &module_vtable,
    },
    .connection = if (build_options.wireguard) .{
        .ptr = &Default.connection_context,
        .vtable = &connection_vtable,
    } else null,
};

const Default = struct {
    var connection_context: connection.ConnectionContext = .{
        .backend = backend.goBackend(),
    };
};

const module_vtable: core.ModuleImplementation.VTable = .{
    .module_type = moduleType,
    .import_module = parser.importModule,
    .serialize_module = serializer.serializeModule,
};

const connection_vtable: net.ConnectionImplementation.VTable = .{
    .module_type = moduleType,
    .create_connection = connection.createConnection,
};

fn moduleType(_: ?*const anyopaque) ModuleType {
    return .WireGuard;
}
