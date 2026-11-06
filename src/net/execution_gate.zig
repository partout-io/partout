// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../core/exports.zig");

/// Serializes Windows protocol callbacks with actor controls and timers.
/// Native producers must never wait: controls can be draining their callbacks.
pub const ExecutionGate = struct {
    mutex: core.Mutex = .{},
    changed: core.Condition = .{},
    busy: bool = false,
    waiters: usize = 0,
    threadlocal var current: ?*ExecutionGate = null;

    pub fn deinit(self: *ExecutionGate) void {
        std.debug.assert(!self.busy and self.waiters == 0);
        self.changed.deinit();
        self.mutex.deinit();
    }

    pub fn enter(self: *ExecutionGate) void {
        std.debug.assert(current == null);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.waiters += 1;
        defer self.waiters -= 1;
        while (self.busy) self.changed.wait(&self.mutex);
        self.busy = true;
        current = self;
    }

    pub fn tryEnter(self: *ExecutionGate) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.busy or self.waiters != 0 or current != null) return false;
        self.busy = true;
        current = self;
        return true;
    }

    pub fn leave(self: *ExecutionGate) void {
        std.debug.assert(current == self);
        self.mutex.lock();
        defer self.mutex.unlock();
        current = null;
        self.busy = false;
        if (self.waiters != 0) self.changed.broadcast();
    }

    pub fn isCurrent(self: *const ExecutionGate) bool {
        return current == self;
    }
};
