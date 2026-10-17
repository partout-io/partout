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
        if (self.event) |callback| {
            callback(self.ctx, payload);
            return;
        }
        // Existing sinks retain their individual callbacks during migration.
        // FIXME: ###, Delete after v2
        switch (payload) {
            .established => |success| self.established(self.ctx, success),
            .needs_rebind => |info| self.needs_rebind(self.ctx, info),
            .failed => |failure| self.failed(self.ctx, failure),
            .stopped => self.stopped(self.ctx),
            .set_env => |update| self.set_env(self.ctx, update.key, update.value),
            .data_count => |count| self.data_count(self.ctx, count),
        }
    }

    ctx: *anyopaque,
    event: ?*const fn (*anyopaque, ConnectionEvent) void = null,
    /// Requests host cancellation after an unrecoverable connection
    /// failure so the daemon can apply its cancellation policy.
    cancel: *const fn (*anyopaque, ?api.PartoutErrorPair) void,

    // FIXME: ###, Deprecated.
    established: *const fn (*anyopaque, Success) void = struct {
        fn call(_: *anyopaque, _: Success) void {}
    }.call,
    needs_rebind: *const fn (*anyopaque, ?api.TunnelRemoteInfoWrapper) void = struct {
        fn call(_: *anyopaque, _: ?api.TunnelRemoteInfoWrapper) void {}
    }.call,
    failed: *const fn (*anyopaque, Failure) void = struct {
        fn call(_: *anyopaque, _: Failure) void {}
    }.call,
    stopped: *const fn (*anyopaque) void = struct {
        fn call(_: *anyopaque) void {}
    }.call,
    set_env: *const fn (*anyopaque, []const u8, ?[]const u8) void = struct {
        fn call(_: *anyopaque, _: []const u8, _: ?[]const u8) void {}
    }.call,
    data_count: *const fn (*anyopaque, api.DataCount) void = struct {
        fn call(_: *anyopaque, _: api.DataCount) void {}
    }.call,
    status: *const fn (*anyopaque, api.ConnectionStatus) void,
    last_error: *const fn (*anyopaque, api.PartoutErrorPair) void,
};
