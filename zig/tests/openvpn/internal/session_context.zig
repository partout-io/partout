// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const session_context = @import("source").openvpn_internal.session_context;

test "ActiveContext declarations are semantically analyzed" {
    std.testing.refAllDecls(session_context.ActiveContext);
}

test "stopped session has no active context" {
    var state = session_context.SessionState{ .stopped = .{ .with_local_options = false } };
    try std.testing.expect(state.activeContext() == null);
}
