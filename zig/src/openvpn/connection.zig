// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");

const api = core.api;

pub fn createConnection(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: net.ConnectionModule,
    sandbox: net.Sandbox,
) net.ConnectionCreateError!net.Connection {
    const raw = ptr orelse return error.MissingConnectionImplementation;
    // ZIGME: Implement OpenVPN connection
    _ = raw;
    _ = allocator;
    _ = module;
    _ = sandbox;
    return error.MissingConnectionImplementation;
}
