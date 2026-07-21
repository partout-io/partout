// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core = @import("../../core/exports.zig");
const ConnectionOptions = @import("connection_options.zig").ConnectionOptions;
const DataChannel = @import("data_channel.zig").DataChannel;
const PushReply = @import("push_reply.zig").PushReply;

const api = core.api;

/// Borrowed session settings and callbacks used by a negotiator.
///
/// `on_connected` transfers the `DataChannel` to the callback on success. The
/// push reply remains borrowed from the negotiator and must be cloned by a
/// recipient that needs to retain it.
pub const NegotiatorOptions = struct {
    configuration: *const api.OpenVPNConfiguration,
    credentials: ?*const api.OpenVPNCredentials,
    with_local_options: bool,
    session_options: ConnectionOptions,
    callback_context: ?*anyopaque,
    on_connected: *const fn (
        ?*anyopaque,
        u8,
        *DataChannel,
        *const PushReply,
    ) anyerror!void,
    on_error: *const fn (?*anyopaque, u8, anyerror) void,
};
