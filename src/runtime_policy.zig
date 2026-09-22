// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Compile-time policy for the daemon, looper, and OpenVPN migration to v2.
//! Keep the platform exception here so all three implementations move together.
const builtin = @import("builtin");

/// Force v2 and exclude legacy implementations, regardless of runtime flags.
/// Set to true when all platforms migrate, or false to restore flag selection.
pub const v2_only = builtin.os.tag == .windows;

pub const legacy_looper = if (v2_only) struct {} else @import("net/looper.zig");
pub const openvpn_connection = if (v2_only) @import("openvpn/connection_v2.zig") else @import("openvpn/connection.zig");
pub const openvpn_session = if (v2_only) @import("openvpn/internal/session_v2.zig") else @import("openvpn/internal/session.zig");
