// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const std = @import("std");

pub const Mutex = switch (builtin.os.tag) {
    .windows => WindowsMutex,
    else => PosixMutex,
};

pub const Condition = switch (builtin.os.tag) {
    .windows => WindowsCondition,
    else => PosixCondition,
};

pub const Drainer = struct {
    in_flight: usize = 0,
    drained: Condition = .{},

    pub fn deinit(self: *Drainer) void {
        self.drained.deinit();
    }

    /// Caller must hold the mutex that protects this drainer.
    pub fn enter(self: *Drainer) void {
        self.in_flight += 1;
    }

    /// Caller must hold the mutex that protects this drainer.
    pub fn drain(self: *Drainer, mutex: *Mutex) void {
        while (self.in_flight > 0) {
            self.drained.wait(mutex);
        }
    }

    pub fn leave(self: *Drainer, mutex: *Mutex) void {
        mutex.lock();
        defer mutex.unlock();

        std.debug.assert(self.in_flight > 0);
        self.in_flight -= 1;
        if (self.in_flight == 0) {
            self.drained.broadcast();
        }
    }
};

pub const RunAfter = struct {
    pub const Callback = *const fn (?*anyopaque) void;

    const State = enum {
        idle,
        scheduled,
        running,
        running_scheduled,
        stopping,
    };

    mutex: Mutex = .{},
    cond: Condition = .{},
    thread: ?std.Thread = null,
    delay_ms: u64 = 0,
    callback: ?Callback = null,
    callback_ctx: ?*anyopaque = null,
    state: State = .idle,
    generation: u64 = 0,

    pub fn init(
        self: *RunAfter,
        delay_ms: u64,
        callback: Callback,
        callback_ctx: ?*anyopaque,
    ) std.Thread.SpawnError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.state != .stopping);
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, RunAfter.run, .{self});
        }

        self.generation +%= 1;
        self.delay_ms = delay_ms;
        self.callback = callback;
        self.callback_ctx = callback_ctx;
        self.state = switch (self.state) {
            .idle, .scheduled => .scheduled,
            .running, .running_scheduled => .running_scheduled,
            .stopping => unreachable,
        };
        self.cond.broadcast();
    }

    pub fn cancel(self: *RunAfter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.generation +%= 1;
        self.callback = null;
        self.callback_ctx = null;
        self.state = switch (self.state) {
            .idle => .idle,
            .scheduled => .idle,
            .running, .running_scheduled => .running,
            .stopping => .stopping,
        };
        self.cond.broadcast();
    }

    pub fn deinit(self: *RunAfter) void {
        self.mutex.lock();
        self.generation +%= 1;
        self.callback = null;
        self.callback_ctx = null;
        self.state = .stopping;
        const thread = self.thread;
        self.thread = null;
        self.cond.broadcast();
        self.mutex.unlock();

        if (thread) |item| item.join();
        self.cond.deinit();
        self.mutex.deinit();
    }

    pub fn wait(self: *RunAfter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.state != .idle) {
            self.cond.wait(&self.mutex);
        }
    }

    fn run(self: *RunAfter) void {
        while (true) {
            self.mutex.lock();
            while (self.state == .idle) {
                self.cond.wait(&self.mutex);
            }
            if (self.state == .stopping) {
                self.mutex.unlock();
                return;
            }
            std.debug.assert(self.state == .scheduled);
            const generation = self.generation;
            const delay_ms = self.delay_ms;
            self.mutex.unlock();

            if (self.sleepUntilChangedOrElapsed(generation, delay_ms)) continue;

            self.mutex.lock();
            if (self.state == .stopping) {
                self.mutex.unlock();
                return;
            }
            if (self.state != .scheduled or self.generation != generation) {
                self.mutex.unlock();
                continue;
            }

            const callback = self.callback;
            const callback_ctx = self.callback_ctx;
            self.state = .running;
            self.mutex.unlock();

            if (callback) |call| call(callback_ctx);

            self.mutex.lock();
            switch (self.state) {
                .running => {
                    self.callback = null;
                    self.callback_ctx = null;
                    self.state = .idle;
                },
                .running_scheduled => self.state = .scheduled,
                .stopping => {
                    self.mutex.unlock();
                    return;
                },
                .idle, .scheduled => unreachable,
            }
            self.cond.broadcast();
            self.mutex.unlock();
        }
    }

    fn sleepUntilChangedOrElapsed(self: *RunAfter, generation: u64, delay_ms: u64) bool {
        const sleep_step_ms = 10;
        var remaining_ms = delay_ms;
        while (remaining_ms > 0) {
            if (self.hasChanged(generation)) return true;

            const current_sleep_ms = @min(remaining_ms, sleep_step_ms);
            sleepMs(current_sleep_ms);
            remaining_ms -= current_sleep_ms;
        }
        return self.hasChanged(generation);
    }

    fn hasChanged(self: *RunAfter, generation: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.state != .scheduled or self.generation != generation;
    }
};

const PosixMutex = struct {
    raw: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PosixMutex) void {
        switch (std.c.pthread_mutex_lock(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn unlock(self: *PosixMutex) void {
        switch (std.c.pthread_mutex_unlock(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn deinit(self: *PosixMutex) void {
        switch (std.c.pthread_mutex_destroy(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }
};

const PosixCondition = struct {
    raw: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *PosixCondition, mutex: *Mutex) void {
        switch (std.c.pthread_cond_wait(&self.raw, &mutex.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn broadcast(self: *PosixCondition) void {
        switch (std.c.pthread_cond_broadcast(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn deinit(self: *PosixCondition) void {
        switch (std.c.pthread_cond_destroy(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }
};

const WindowsMutex = struct {
    raw: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn lock(self: *WindowsMutex) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.raw);
    }

    pub fn unlock(self: *WindowsMutex) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.raw);
    }

    pub fn deinit(_: *WindowsMutex) void {}
};

const WindowsCondition = struct {
    const windows = std.os.windows;

    extern "ntdll" fn RtlSleepConditionVariableSRW(
        ConditionVariable: *windows.CONDITION_VARIABLE,
        SRWLock: *windows.SRWLOCK,
        Timeout: ?*const windows.LARGE_INTEGER,
        Flags: windows.ULONG,
    ) callconv(.winapi) windows.NTSTATUS;

    raw: windows.CONDITION_VARIABLE = windows.CONDITION_VARIABLE_INIT,

    pub fn wait(self: *WindowsCondition, mutex: *Mutex) void {
        switch (RtlSleepConditionVariableSRW(&self.raw, &mutex.raw, null, 0)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    pub fn broadcast(self: *WindowsCondition) void {
        windows.ntdll.RtlWakeAllConditionVariable(&self.raw);
    }

    pub fn deinit(_: *WindowsCondition) void {}
};

pub fn sleepMs(value: u64) void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const bounded = @min(value, @as(u64, @intCast(std.math.maxInt(i64) / 10_000)));
        var interval: windows.LARGE_INTEGER = -@as(i64, @intCast(bounded * 10_000));
        _ = windows.ntdll.NtDelayExecution(.FALSE, &interval);
        return;
    }
    var request = std.c.timespec{
        .sec = @intCast(value / std.time.ms_per_s),
        .nsec = @intCast((value % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    var remaining: std.c.timespec = undefined;
    while (std.c.nanosleep(&request, &remaining) != 0) {
        request = remaining;
    }
}
