// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const ActiveContext = @import("active_context.zig").ActiveContext;
const ActivePhase = @import("active_phase.zig").ActivePhase;
const IdleContext = @import("idle_context.zig").IdleContext;

/// Serialized lifecycle state for a V3 OpenVPN session.
///
/// The active context is heap allocated because callbacks stored by its data
/// link borrow it indirectly through the owning `Session`; keeping it behind a
/// pointer also prevents accidental moves of its owning channel collections.
pub const SessionState = union(enum) {
    stopped: IdleContext,
    active: Active,

    pub const Active = struct {
        phase: ActivePhase,
        context: *ActiveContext,
    };

    pub fn activePhase(self: SessionState) ?ActivePhase {
        return switch (self) {
            .stopped => null,
            .active => |active| active.phase,
        };
    }

    pub fn idleContext(self: *SessionState) ?*IdleContext {
        return switch (self.*) {
            .stopped => |*context| context,
            .active => null,
        };
    }

    pub fn activeState(self: *SessionState) ?*Active {
        return switch (self.*) {
            .stopped => null,
            .active => |*active| active,
        };
    }

    pub fn activeContext(self: *SessionState) ?*ActiveContext {
        const active = self.activeState() orelse return null;
        return active.context;
    }
};

test "stopped session exposes only its idle context" {
    const std = @import("std");
    var state = SessionState{ .stopped = .{ .with_local_options = false } };
    try std.testing.expect(state.activePhase() == null);
    try std.testing.expect(state.activeContext() == null);
    try std.testing.expect(!state.idleContext().?.with_local_options);
}
