// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const core = @import("../core/exports.zig");
const io = @import("io_common.zig");
const c = io.io_c;

/// Shared readiness wake. Callers serialize access with their I/O lock;
/// wait() releases that lock while blocking and reacquires it before returning.
pub const Waiter = struct {
    mux: c.pp_mux = null,
    pending: usize = 0,
    released: bool = false,

    pub fn wake(self: *Waiter) void {
        if (self.pending != 0) _ = c.pp_mux_wake(self.mux);
    }

    pub fn deinit(self: *Waiter) void {
        self.wake();
        self.released = true;
        self.freeIfReleased();
    }

    fn freeIfReleased(self: *Waiter) void {
        if (self.released and self.pending == 0) {
            c.pp_mux_free(self.mux);
            self.* = .{};
        }
    }

    /// A null descriptor waits only for wake. Returns true for I/O readiness.
    pub fn wait(self: *Waiter, fd: ?c.pp_fd, writing: bool, lock: ?*core.Mutex) io.Error!bool {
        if (self.mux == null) self.mux = c.pp_mux_create(1) orelse return error.LibcFailure;
        self.pending += 1;
        defer {
            self.pending -= 1;
            // Every concurrent waiter must observe wake before it is reset.
            if (self.pending == 0) _ = c.pp_mux_reset_wake(self.mux);
            self.freeIfReleased();
        }
        if (lock) |mutex| mutex.unlock();
        defer if (lock) |mutex| mutex.lock();
        const result = c.pp_mux_wait_once(fd orelse c.pp_fd_invalid(), writing, c.pp_mux_wake_descriptor(self.mux));
        if (result < 0) return error.LibcFailure;
        return result > 0;
    }
};
