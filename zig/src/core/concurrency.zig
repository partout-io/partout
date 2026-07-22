// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Small cross-platform concurrency primitives used throughout the core.
//!
//! `Mutex` and `Condition` provide the same blocking interface on POSIX and
//! Windows. `Drainer` coordinates shutdown with externally synchronized work,
//! while `RunAfter` owns a reusable worker for delayed callbacks. Stateful
//! values are ready for use after zero initialization and require an explicit
//! `deinit` before their storage is released.

const builtin = @import("builtin");
const std = @import("std");

/// Exclusive, non-recursive mutex backed by the host operating system.
///
/// A mutex is ready for use as `Mutex{}`. The caller must ensure that it is
/// unlocked and has no contenders before calling `deinit`.
pub const Mutex = switch (builtin.os.tag) {
    .windows => WindowsMutex,
    else => PosixMutex,
};

/// Condition variable paired with `Mutex`.
///
/// Waiters must always check their predicate in a loop because a broadcast
/// does not imply that the predicate remains true after the mutex is reacquired.
pub const Condition = switch (builtin.os.tag) {
    .windows => WindowsCondition,
    else => PosixCondition,
};

/// Counts externally synchronized work and allows a caller to wait for it to
/// drain.
///
/// The owner supplies the `Mutex` that protects both `in_flight` and any state
/// governing admission of new work. `Drainer` does not prevent new calls to
/// `enter`; callers normally close admission before calling `drain`.
pub const Drainer = struct {
    /// Number of work items that entered but have not yet left.
    in_flight: usize = 0,

    /// Wakes drainers when `in_flight` reaches zero.
    drained: Condition = .{},

    /// Releases the internal condition variable.
    ///
    /// No thread may be waiting in `drain` when this function is called.
    pub fn deinit(self: *Drainer) void {
        self.drained.deinit();
    }

    /// Registers one in-flight work item.
    ///
    /// The caller must hold the mutex that protects this drainer.
    pub fn enter(self: *Drainer) void {
        self.in_flight += 1;
    }

    /// Blocks until every registered work item has left.
    ///
    /// The caller must hold `mutex`. Waiting temporarily releases it, and the
    /// function returns with it held again.
    pub fn drain(self: *Drainer, mutex: *Mutex) void {
        while (self.in_flight > 0) {
            self.drained.wait(mutex);
        }
    }

    /// Completes one work item, acquiring `mutex` around the state change.
    ///
    /// Use `leaveLocked` instead when the caller already holds the mutex.
    pub fn leave(self: *Drainer, mutex: *Mutex) void {
        mutex.lock();
        defer mutex.unlock();

        self.leaveLocked();
    }

    /// Completes one work item while the protecting mutex is already held.
    ///
    /// The caller must previously have paired this call with `enter`.
    pub fn leaveLocked(self: *Drainer) void {
        std.debug.assert(self.in_flight > 0);
        self.in_flight -= 1;
        if (self.in_flight == 0) {
            self.drained.broadcast();
        }
    }
};

/// Reusable single-threaded executor for delayed, one-shot callbacks.
///
/// `init` manages one replaceable callback, whereas `schedule` manages several
/// independent callbacks through caller-owned `Scheduled` handles. The two
/// scheduling modes must not be mixed while either mode has pending work.
/// Callbacks run serially on the same worker thread and never under the
/// executor mutex.
///
/// The `RunAfter` value and every borrowed callback context must remain alive
/// until the corresponding callback completes or is cancelled. `deinit` joins
/// the worker and therefore must not be called from one of its callbacks.
pub const RunAfter = struct {
    /// Callback used by the replaceable `init` scheduling mode.
    pub const Callback = *const fn (?*anyopaque) void;

    /// Caller-owned handle for an independent one-shot callback.
    ///
    /// A handle can be submitted once at a time and must remain at a stable
    /// address until its callback reports either `.elapsed` or `.cancelled`.
    /// After that notification returns, the caller may reuse or release it.
    pub const Scheduled = struct {
        /// Terminal reason delivered to a scheduled callback.
        pub const Outcome = enum {
            /// The requested delay elapsed and the callback became due.
            elapsed,

            /// The callback was still pending when its executor was cancelled
            /// or deinitialized.
            cancelled,
        };

        /// Callback invoked exactly once for a submitted `Scheduled` handle.
        ///
        /// The callback runs without the executor mutex held and may inspect
        /// `scheduled.context`. The executor does not access the handle again
        /// after the callback returns.
        pub const Callback = *const fn (*Scheduled, Outcome) void;

        /// Borrowed application context supplied to `schedule`.
        context: ?*anyopaque = null,

        /// Callback to notify when this handle reaches a terminal outcome.
        callback: ?Scheduled.Callback = null,

        /// Approximate delay remaining in scheduler ticks.
        remaining_ms: u64 = 0,

        /// Private intrusive linkage used by the executor's pending list.
        next: ?*Scheduled = null,
    };

    /// Lifecycle of the replaceable callback slot and worker thread.
    const State = enum {
        /// The worker exists, or may not have been started yet, with no callback
        /// waiting or executing.
        idle,

        /// A callback is waiting for its delay to elapse.
        scheduled,

        /// A callback is currently executing with no successor scheduled.
        running,

        /// A callback is executing and another callback is waiting behind it.
        running_scheduled,

        /// Destruction was requested and the worker must exit.
        stopping,
    };

    /// Protects every mutable field in the executor.
    mutex: Mutex = .{},

    /// Wakes the worker on scheduling changes and waiters on state changes.
    cond: Condition = .{},

    /// Reusable worker thread, created lazily and joined by `deinit`.
    thread: ?std.Thread = null,

    /// Delay associated with the replaceable callback slot.
    delay_ms: u64 = 0,

    /// Replaceable callback waiting in, or executing from, the callback slot.
    callback: ?Callback = null,

    /// Borrowed context passed to `callback`.
    callback_ctx: ?*anyopaque = null,

    /// Current lifecycle of the replaceable callback slot.
    state: State = .idle,

    /// Version of the slot, incremented to invalidate an in-progress delay.
    generation: u64 = 0,

    /// First independent callback waiting for a scheduler tick.
    scheduled_head: ?*Scheduled = null,

    /// Last independent callback, retained for constant-time insertion.
    scheduled_tail: ?*Scheduled = null,

    /// Whether the replaceable callback slot is driving scheduler ticks for
    /// the independent callback list.
    scheduling: bool = false,

    /// Starts the reusable worker without scheduling a callback.
    ///
    /// Calling this function more than once is harmless. The worker remains
    /// alive and idle until `deinit`, even if all callbacks have completed. A
    /// spawn error is possible only when the worker is first created.
    pub fn start(self: *RunAfter) std.Thread.SpawnError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.state != .stopping);
        try self.startLocked();
    }

    /// Schedules the replaceable one-shot callback.
    ///
    /// A pending callback previously submitted with `init` is silently
    /// replaced. If a callback is already running, the new callback waits for
    /// it to return before its own delay begins being serviced. This mode must
    /// not be used while independent callbacks from `schedule` are pending.
    /// The function starts the worker lazily and reports failure to spawn it.
    pub fn init(
        self: *RunAfter,
        delay_ms: u64,
        callback: Callback,
        callback_ctx: ?*anyopaque,
    ) std.Thread.SpawnError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.state != .stopping);
        std.debug.assert(!self.scheduling);
        try self.startLocked();

        self.initLocked(delay_ms, callback, callback_ctx);
    }

    /// Adds an independent one-shot callback without replacing earlier ones.
    ///
    /// Delays are best-effort and quantized to `scheduler_resolution_ms`; a
    /// callback may run late but is given a full extra tick so it does not run
    /// early at a tick boundary. This mode must not be started while a callback
    /// submitted with `init` is pending. The function starts the worker lazily
    /// and reports failure to spawn it.
    pub fn schedule(
        self: *RunAfter,
        scheduled: *Scheduled,
        delay_ms: u64,
        callback: Scheduled.Callback,
        context: ?*anyopaque,
    ) std.Thread.SpawnError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.state != .stopping);
        std.debug.assert(self.scheduling or self.state != .scheduled);
        try self.startLocked();

        scheduled.* = .{
            .context = context,
            .callback = callback,
            // A full extra tick prevents a newly appended job from expiring
            // early when it lands immediately before the current tick.
            .remaining_ms = delay_ms +| scheduler_resolution_ms,
        };
        if (self.scheduled_tail) |tail| {
            tail.next = scheduled;
        } else {
            self.scheduled_head = scheduled;
        }
        self.scheduled_tail = scheduled;

        if (!self.scheduling) {
            self.scheduling = true;
            self.initLocked(scheduler_resolution_ms, runScheduled, self);
        }
    }

    /// Cancels pending callbacks without stopping the worker thread.
    ///
    /// A callback that is already running is allowed to finish. Any queued
    /// successor from `init` is discarded, and every independent callback that
    /// is still pending is synchronously notified with `.cancelled` after the
    /// executor mutex is released.
    pub fn cancel(self: *RunAfter) void {
        self.mutex.lock();
        const cancelled = self.cancelLocked();
        self.mutex.unlock();

        notifyScheduled(cancelled, .cancelled);
    }

    /// Cancels pending callbacks, stops and joins the worker, then releases the
    /// synchronization primitives.
    ///
    /// If a callback is running, this function waits for it to return. It must
    /// be called exactly once, from outside the worker thread, after all other
    /// operations on this executor have ceased.
    pub fn deinit(self: *RunAfter) void {
        self.mutex.lock();
        const cancelled = self.takeScheduledLocked();
        self.scheduling = false;
        self.generation +%= 1;
        self.callback = null;
        self.callback_ctx = null;
        self.state = .stopping;
        const thread = self.thread;
        self.thread = null;
        self.cond.broadcast();
        self.mutex.unlock();

        notifyScheduled(cancelled, .cancelled);
        if (thread) |item| item.join();
        self.cond.deinit();
        self.mutex.deinit();
    }

    /// Blocks until no replaceable callback is pending or running.
    ///
    /// In independent scheduling mode, the internal tick callback keeps the
    /// executor non-idle until every scheduled handle has been notified. This
    /// function must not race with `deinit` or run from an executor callback.
    pub fn wait(self: *RunAfter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.state != .idle) {
            self.cond.wait(&self.mutex);
        }
    }

    /// Worker entry point for the replaceable callback slot.
    ///
    /// The worker sleeps while idle, evaluates delays without holding `mutex`,
    /// and serializes callback execution. It exits only after entering
    /// `.stopping`.
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

    /// Processes one scheduler tick for the independent callback list.
    ///
    /// Due handles are detached while holding `mutex`, the next tick is armed
    /// if necessary, and notifications are delivered after unlocking.
    fn runScheduled(context: ?*anyopaque) void {
        const self: *RunAfter = @ptrCast(@alignCast(context.?));

        self.mutex.lock();
        if (!self.scheduling) {
            self.mutex.unlock();
            return;
        }

        var due_head: ?*Scheduled = null;
        var due_tail: ?*Scheduled = null;
        var previous: ?*Scheduled = null;
        var current = self.scheduled_head;
        while (current) |scheduled| {
            const next = scheduled.next;
            scheduled.remaining_ms -|= scheduler_resolution_ms;
            if (scheduled.remaining_ms == 0) {
                if (previous) |before| {
                    before.next = next;
                } else {
                    self.scheduled_head = next;
                }
                if (self.scheduled_tail == scheduled) self.scheduled_tail = previous;

                scheduled.next = null;
                if (due_tail) |tail| {
                    tail.next = scheduled;
                } else {
                    due_head = scheduled;
                }
                due_tail = scheduled;
            } else {
                previous = scheduled;
            }
            current = next;
        }

        if (self.scheduled_head != null) {
            self.initLocked(scheduler_resolution_ms, runScheduled, self);
        } else {
            self.scheduling = false;
        }
        self.mutex.unlock();

        notifyScheduled(due_head, .elapsed);
    }

    /// Replaces or follows the callback slot while `mutex` is held.
    ///
    /// Incrementing `generation` interrupts any delay currently being observed
    /// by the worker.
    fn initLocked(
        self: *RunAfter,
        delay_ms: u64,
        callback: Callback,
        callback_ctx: ?*anyopaque,
    ) void {
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

    /// Starts the worker lazily while `mutex` is held.
    fn startLocked(self: *RunAfter) std.Thread.SpawnError!void {
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, RunAfter.run, .{self});
        }
    }

    /// Cancels queued work while `mutex` is held.
    ///
    /// Returns the detached independent callbacks so their user code can be
    /// notified after the mutex is released.
    fn cancelLocked(self: *RunAfter) ?*Scheduled {
        const cancelled = self.takeScheduledLocked();
        self.scheduling = false;
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
        return cancelled;
    }

    /// Detaches the entire independent callback list while `mutex` is held.
    fn takeScheduledLocked(self: *RunAfter) ?*Scheduled {
        const scheduled = self.scheduled_head;
        self.scheduled_head = null;
        self.scheduled_tail = null;
        return scheduled;
    }

    /// Delivers `outcome` to a detached list of independent callbacks.
    ///
    /// No executor lock is held while application callbacks run.
    fn notifyScheduled(head: ?*Scheduled, outcome: Scheduled.Outcome) void {
        var current = head;
        while (current) |scheduled| {
            const next = scheduled.next;
            scheduled.next = null;
            if (scheduled.callback) |callback| callback(scheduled, outcome);
            current = next;
        }
    }

    /// Sleeps for `delay_ms` unless the observed callback slot changes.
    ///
    /// Returns `true` when the generation or state changed and the caller must
    /// discard the elapsed-delay result. Polling bounds rescheduling latency to
    /// roughly `sleep_step_ms` without requiring timed condition waits.
    fn sleepUntilChangedOrElapsed(self: *RunAfter, generation: u64, delay_ms: u64) bool {
        // Maximum sleep interval between generation checks.
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

    /// Reports whether `generation` still identifies the scheduled slot.
    fn hasChanged(self: *RunAfter, generation: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.state != .scheduled or self.generation != generation;
    }

    /// Tick resolution used for independent scheduled callbacks.
    const scheduler_resolution_ms = 10;
};

/// POSIX implementation of `Mutex` using `pthread_mutex_t`.
const PosixMutex = struct {
    /// Native mutex storage, statically initialized for zero-cost construction.
    raw: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    /// Acquires exclusive ownership, blocking until the mutex is available.
    ///
    /// Relocking from the owning thread is unsupported.
    pub fn lock(self: *PosixMutex) void {
        switch (std.c.pthread_mutex_lock(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    /// Releases exclusive ownership.
    ///
    /// The calling thread must currently own the mutex.
    pub fn unlock(self: *PosixMutex) void {
        switch (std.c.pthread_mutex_unlock(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    /// Destroys the native mutex.
    ///
    /// The mutex must be unlocked and have no waiting threads.
    pub fn deinit(self: *PosixMutex) void {
        switch (std.c.pthread_mutex_destroy(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }
};

/// POSIX implementation of `Condition` using `pthread_cond_t`.
const PosixCondition = struct {
    /// Native condition-variable storage, statically initialized.
    raw: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    /// Atomically releases `mutex`, waits until woken, and reacquires it.
    ///
    /// The caller must own `mutex` and must recheck its predicate after this
    /// function returns.
    pub fn wait(self: *PosixCondition, mutex: *Mutex) void {
        switch (std.c.pthread_cond_wait(&self.raw, &mutex.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    /// Wakes every thread currently waiting on this condition variable.
    ///
    /// Waiters still serialize on their associated mutex before returning.
    pub fn broadcast(self: *PosixCondition) void {
        switch (std.c.pthread_cond_broadcast(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    /// Destroys the native condition variable.
    ///
    /// No thread may still be waiting on it.
    pub fn deinit(self: *PosixCondition) void {
        switch (std.c.pthread_cond_destroy(&self.raw)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }
};

/// Windows implementation of `Mutex` using an exclusive slim reader/writer
/// lock.
const WindowsMutex = struct {
    /// Native SRW lock storage, statically initialized.
    raw: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    /// Acquires the SRW lock in exclusive mode, blocking as necessary.
    ///
    /// SRW locks are non-recursive; the owning thread must not lock twice.
    pub fn lock(self: *WindowsMutex) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.raw);
    }

    /// Releases exclusive ownership of the SRW lock.
    pub fn unlock(self: *WindowsMutex) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.raw);
    }

    /// Completes the common mutex lifecycle.
    ///
    /// Windows SRW locks do not require native destruction. The caller must
    /// nevertheless ensure that the lock has no owner or waiters.
    pub fn deinit(_: *WindowsMutex) void {}
};

/// Windows implementation of `Condition` using a native condition variable.
const WindowsCondition = struct {
    /// Namespace alias for the Windows ABI types used by this implementation.
    const windows = std.os.windows;

    /// Native wait operation paired with an SRW lock.
    ///
    /// Zig's Windows bindings do not expose this ntdll entry point directly on
    /// every supported SDK, so it is declared here with its native ABI.
    extern "ntdll" fn RtlSleepConditionVariableSRW(
        ConditionVariable: *windows.CONDITION_VARIABLE,
        SRWLock: *windows.SRWLOCK,
        Timeout: ?*const windows.LARGE_INTEGER,
        Flags: windows.ULONG,
    ) callconv(.winapi) windows.NTSTATUS;

    /// Native condition-variable storage, statically initialized.
    raw: windows.CONDITION_VARIABLE = windows.CONDITION_VARIABLE_INIT,

    /// Atomically releases `mutex`, waits until woken, and reacquires it in
    /// exclusive mode.
    ///
    /// The caller must own `mutex` and must recheck its predicate after this
    /// function returns.
    pub fn wait(self: *WindowsCondition, mutex: *Mutex) void {
        switch (RtlSleepConditionVariableSRW(&self.raw, &mutex.raw, null, 0)) {
            .SUCCESS => {},
            else => unreachable,
        }
    }

    /// Wakes every thread currently waiting on this condition variable.
    pub fn broadcast(self: *WindowsCondition) void {
        windows.ntdll.RtlWakeAllConditionVariable(&self.raw);
    }

    /// Completes the common condition-variable lifecycle.
    ///
    /// Native Windows condition variables require no destruction. No thread
    /// may still be waiting when this function is called.
    pub fn deinit(_: *WindowsCondition) void {}
};

/// Blocks the current thread for approximately `value` milliseconds.
///
/// The delay is relative and may run longer because of scheduler activity. On
/// POSIX, interrupted sleeps resume with the reported remaining duration. On
/// Windows, values are bounded to the largest relative interval representable
/// by `LARGE_INTEGER` in 100-nanosecond units.
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
