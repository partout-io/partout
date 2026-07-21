// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core = @import("../../core/exports.zig");

const api = core.api;

/// Type-erased observer for major session events.
///
/// Values passed to callbacks are borrowed for the duration of the callback.
/// The delegate context must outlive its registration with the session.
/// Callbacks execute on the session looper; synchronous lifecycle operations
/// must be handed off to another thread rather than called reentrantly.
pub const SessionDelegate = struct {
    context: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        did_start: *const fn (
            ?*anyopaque,
            *anyopaque,
            api.ExtendedEndpoint,
            api.OpenVPNConfiguration,
        ) void,
        did_stop: *const fn (?*anyopaque, *anyopaque, ?anyerror) void,
        did_update_data_count: *const fn (
            ?*anyopaque,
            *anyopaque,
            api.DataCount,
        ) void,
    };

    pub fn didStart(
        self: SessionDelegate,
        session: *anyopaque,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: api.OpenVPNConfiguration,
    ) void {
        self.vtable.did_start(
            self.context,
            session,
            remote_endpoint,
            remote_options,
        );
    }

    pub fn didStop(
        self: SessionDelegate,
        session: *anyopaque,
        cause: ?anyerror,
    ) void {
        self.vtable.did_stop(self.context, session, cause);
    }

    pub fn didUpdateDataCount(
        self: SessionDelegate,
        session: *anyopaque,
        count: api.DataCount,
    ) void {
        self.vtable.did_update_data_count(self.context, session, count);
    }
};
