// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");

const api = core.api;

pub const StartError = error{
    OTPEncoding,
};

pub const Error = enum {
    /// Programming errors.
    Assertion,
    /// The provided credentials failed authentication.
    BadCredentials,
    /// The provided credentials failed authentication, but should retry without local options.
    BadCredentialsWithLocalOptions,
    /// The connection key is wrong or wasn't expected.
    BadKey,
    /// Control channel failure.
    ControlChannel,
    /// The reply to PUSH_REQUEST is malformed.
    MalformedPushReply,
    /// The VPN session id is missing.
    MissingSessionId,
    /// Errors from the internal layer.
    Native,
    /// The negotiation timed out.
    NegotiationTimeout,
    /// Missing routing information.
    NoRouting,
    /// The server couldn't ping back before timeout.
    PingTimeout,
    /// Recoverable error (reconnecting may resolve).
    Recoverable,
    /// Server uses compression.
    ServerCompression,
    /// Remote server shut down (--explicit-exit-notify).
    ServerShutdown,
    /// The VPN session id doesn't match.
    SessionMismatch,
    /// The session reached a stale state and can't be recovered.
    StaleSession,
    /// A write operation took too long.
    WriteTimeout,
    /// The control packet has an incorrect prefix payload.
    WrongControlDataPrefix,
};

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
