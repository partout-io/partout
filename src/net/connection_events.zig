// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core = @import("../core/exports.zig");
const io = @import("io.zig");

const api = core.api;

/// Notification payloads borrowed for the duration of ConnectionEvents.emit().
pub const ConnectionEvent = union(enum) {
    established: ConnectionEvents.Success,
    /// Refresh the link, optionally replacing TUN with the supplied settings.
    /// Restart gracefully when in-place rebind is unsupported.
    needs_rebind: ?api.TunnelRemoteInfoWrapper,
    failed: ConnectionEvents.Failure,
    stopped,
    set_env: struct {
        key: []const u8,
        value: ?[]const u8,
    },
    data_count: api.DataCount,
};

pub const ConnectionEvents = struct {
    pub const Success = struct {
        remote_endpoint: ?io.SocketEndpoint = null,
        info: api.TunnelRemoteInfoWrapper,
    };
    pub const FailureDisposition = enum {
        reconnect,
        cancel,
    };

    pub const Failure = struct {
        /// The borrowed subcode must outlive asynchronous event delivery.
        err_pair: api.PartoutErrorPair,
        disposition: FailureDisposition,
    };

    /// Delegates directly; the receiver decides which events require deferral.
    pub fn emit(self: ConnectionEvents, payload: ConnectionEvent) void {
        self.event(self.ctx, payload);
    }

    ctx: *anyopaque,
    event: *const fn (*anyopaque, ConnectionEvent) void,
};
