// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");

/// This is the facade of all module-specific implementations. It provides
/// methods to import a module, serialize it to a well-known format (if
/// any format exists at all), and create a `Connection` from it.
pub const ModuleExports = struct {
    module: core.ModuleImplementation,
    connection: ?net.ConnectionImplementation = null,
};
