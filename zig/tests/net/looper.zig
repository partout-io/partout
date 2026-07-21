// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");
const io = source.net_io;

const Looper = source.net_looper.Looper;
const AtomicBool = std.atomic.Value(bool);
const AtomicU64 = std.atomic.Value(u64);

const libc = struct {
    extern "c" fn close(fd: std.c.fd_t) c_int;
};

fn waitUntil(value: *const AtomicBool) void {
    while (!value.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

fn yieldRepeatedly() void {
    for (0..1000) |_| {
        std.Thread.yield() catch {};
    }
}

fn monotonicMs() u64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var frequency: windows.LARGE_INTEGER = undefined;
        var counter: windows.LARGE_INTEGER = undefined;
        std.debug.assert(windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool());
        std.debug.assert(windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool());
        const frequency_u64: u64 = @bitCast(frequency);
        const counter_u64: u64 = @bitCast(counter);
        return @intCast((@as(u128, counter_u64) * std.time.ms_per_s) / frequency_u64);
    }

    var timestamp: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &timestamp) == 0);
    return @as(u64, @intCast(timestamp.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(@divTrunc(timestamp.nsec, std.time.ns_per_ms)));
}

fn waitUntilWithin(value: *const AtomicU64, timeout_ms: u64) bool {
    const deadline_ms = monotonicMs() + timeout_ms;
    while (value.load(.acquire) == 0 and monotonicMs() < deadline_ms) {
        source.core.sleepMs(1);
    }
    return value.load(.acquire) != 0;
}

const Pipe = struct {
    fds: [2]std.c.fd_t,

    fn init() !Pipe {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        return .{ .fds = fds };
    }

    fn deinit(self: Pipe) void {
        _ = libc.close(self.fds[0]);
        _ = libc.close(self.fds[1]);
    }

    fn makeReadable(self: Pipe) !void {
        const byte = [_]u8{1};
        if (std.c.write(self.fds[1], &byte, byte.len) != byte.len) {
            return error.PipeWriteFailed;
        }
    }
};

const MockIO = struct {
    fail_reads: AtomicBool = AtomicBool.init(false),
    fail_writes: AtomicBool = AtomicBool.init(false),
    cleaned: AtomicBool = AtomicBool.init(false),

    fn interface(self: *MockIO) io.IOInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setEventMask(_: *anyopaque, _: bool, _: bool) io.Error!void {}

    fn resetEvents(_: *anyopaque) io.Error!void {}

    fn read(raw: *anyopaque, _: []u8) io.Error!?usize {
        const self: *MockIO = @ptrCast(@alignCast(raw));
        if (self.fail_reads.load(.acquire)) return error.EndOfStream;
        return null;
    }

    fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        const self: *MockIO = @ptrCast(@alignCast(raw));
        if (self.fail_writes.load(.acquire)) return error.EndOfStream;
        return data.len - offset;
    }

    fn cleanup(raw: *anyopaque) void {
        const self: *MockIO = @ptrCast(@alignCast(raw));
        self.cleaned.store(true, .release);
    }

    fn lastErrorCode(_: *anyopaque) c_int {
        return 0;
    }

    const vtable = io.IOInterface.VTable{
        .set_event_mask = setEventMask,
        .reset_events = resetEvents,
        .read = read,
        .write = write,
        .cleanup = cleanup,
        .last_error_code = lastErrorCode,
    };
};

fn noopFinish(_: ?*anyopaque, _: ?Looper.Failure) void {}

fn noopTask(_: ?*anyopaque) anyerror!void {}

fn returnFortyTwo(_: ?*anyopaque) anyerror!u8 {
    return 42;
}

fn initLooper(on_finish: Looper.OnFinish) !Looper {
    return Looper.init(std.testing.allocator, .{ .on_finish = on_finish });
}

fn descriptor(pipe: Pipe, mock: *MockIO) Looper.Descriptor {
    return .{
        .fd = pipe.fds[0],
        .io = mock.interface(),
    };
}

const DelayedTaskProbe = struct {
    looper: *Looper,
    fired_at_ms: AtomicU64 = AtomicU64.init(0),
    ran_on_queue: AtomicBool = AtomicBool.init(false),

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *DelayedTaskProbe = @ptrCast(@alignCast(raw.?));
        self.ran_on_queue.store(self.looper.isOnQueue(), .release);
        self.fired_at_ms.store(monotonicMs(), .release);
    }
};

const CancellationProbe = struct {
    fired: AtomicBool = AtomicBool.init(false),

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *CancellationProbe = @ptrCast(@alignCast(raw.?));
        self.fired.store(true, .release);
    }
};

const FinishCallProbe = struct {
    called: AtomicBool = AtomicBool.init(false),

    fn onFinish(raw: ?*anyopaque, _: ?Looper.Failure) void {
        const self: *FinishCallProbe = @ptrCast(@alignCast(raw.?));
        self.called.store(true, .release);
    }
};

test "perform completes synchronously with its result" {
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();

    try std.testing.expectEqual(
        @as(u8, 42),
        try looper.perform(u8, null, returnFortyTwo),
    );
    try looper.stop();
}

test "delayed task waits for its deadline and runs on the looper" {
    const delay_ms = 100;
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();
    var probe = DelayedTaskProbe{ .looper = &looper };

    const scheduled_at_ms = monotonicMs();
    try looper.schedule(delay_ms, .{
        .context = &probe,
        .callback = DelayedTaskProbe.run,
    });

    source.core.sleepMs(15);
    try std.testing.expectEqual(@as(u64, 0), probe.fired_at_ms.load(.acquire));
    try std.testing.expect(waitUntilWithin(&probe.fired_at_ms, 750));

    const fired_at_ms = probe.fired_at_ms.load(.acquire);
    // Keep a tiny tolerance for millisecond conversion at the wait boundary.
    try std.testing.expect(fired_at_ms + 2 >= scheduled_at_ms + delay_ms);
    try std.testing.expect(probe.ran_on_queue.load(.acquire));
    try looper.stop();
}

test "an earlier deadline interrupts a later timed wait" {
    const later_delay_ms = 500;
    const earlier_delay_ms = 40;
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();
    var later = DelayedTaskProbe{ .looper = &looper };
    var earlier = DelayedTaskProbe{ .looper = &looper };

    const later_scheduled_at_ms = monotonicMs();
    try looper.schedule(later_delay_ms, .{
        .context = &later,
        .callback = DelayedTaskProbe.run,
    });
    // A synchronous barrier proves that the loop has observed the later task;
    // then give it a moment to enter the timed mux wait for that deadline.
    try looper.performTask(.{ .callback = noopTask });
    source.core.sleepMs(10);

    const earlier_scheduled_at_ms = monotonicMs();
    try looper.schedule(earlier_delay_ms, .{
        .context = &earlier,
        .callback = DelayedTaskProbe.run,
    });

    try std.testing.expect(waitUntilWithin(&earlier.fired_at_ms, 250));
    const earlier_fired_at_ms = earlier.fired_at_ms.load(.acquire);
    try std.testing.expect(earlier_fired_at_ms + 2 >= earlier_scheduled_at_ms + earlier_delay_ms);
    try std.testing.expect(earlier_fired_at_ms < later_scheduled_at_ms + later_delay_ms);
    try std.testing.expectEqual(@as(u64, 0), later.fired_at_ms.load(.acquire));
    try std.testing.expect(earlier.ran_on_queue.load(.acquire));
    try looper.stop();
}

test "stop and deinit cancel delayed tasks" {
    const delay_ms = 300;

    var stopped_looper = try initLooper(.{ .callback = noopFinish });
    defer stopped_looper.deinit();
    try stopped_looper.start();
    var stopped_probe = CancellationProbe{};
    try stopped_looper.schedule(delay_ms, .{
        .context = &stopped_probe,
        .callback = CancellationProbe.run,
    });
    try stopped_looper.stop();

    var deinitialized_looper = try initLooper(.{ .callback = noopFinish });
    var needs_deinit = true;
    defer if (needs_deinit) deinitialized_looper.deinit();
    try deinitialized_looper.start();
    var deinitialized_probe = CancellationProbe{};
    try deinitialized_looper.schedule(delay_ms, .{
        .context = &deinitialized_probe,
        .callback = CancellationProbe.run,
    });
    deinitialized_looper.deinit();
    needs_deinit = false;

    source.core.sleepMs(delay_ms + 50);
    try std.testing.expect(!stopped_probe.fired.load(.acquire));
    try std.testing.expect(!deinitialized_probe.fired.load(.acquire));
}

test "deinit does not invoke the finish callback" {
    var probe = FinishCallProbe{};
    var looper = try initLooper(.{
        .context = &probe,
        .callback = FinishCallProbe.onFinish,
    });
    try looper.start();

    looper.deinit();

    try std.testing.expect(!probe.called.load(.acquire));
}

test "perform completion is released before later commands finish" {
    var first_task = BlockingTask{};
    var second_task = BlockingTask{};
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();

    // Hold the loop so perform and the second task land in the same detached
    // command batch, in that order.
    try looper.schedule(null, .{
        .context = &first_task,
        .callback = BlockingTask.run,
    });
    waitUntil(&first_task.entered);

    var worker = PerformWorker{ .looper = &looper };
    var worker_thread = try std.Thread.spawn(.{}, PerformWorker.run, .{&worker});
    var worker_joined = false;
    defer if (!worker_joined) {
        first_task.release.store(true, .release);
        second_task.release.store(true, .release);
        worker_thread.join();
    };
    waitUntil(&worker.started);
    yieldRepeatedly();

    try looper.schedule(null, .{
        .context = &second_task,
        .callback = BlockingTask.run,
    });
    first_task.release.store(true, .release);
    waitUntil(&second_task.entered);
    yieldRepeatedly();
    const completed_before_second_task = worker.done.load(.acquire);

    second_task.release.store(true, .release);
    worker_thread.join();
    worker_joined = true;

    try std.testing.expect(completed_before_second_task);
    try std.testing.expect(worker.failure == null);
    try looper.stop();
}

test "work is rejected before start and after terminal cleanup" {
    var finish_probe = FinishProbe{};
    var looper = try initLooper(.{
        .context = &finish_probe,
        .callback = FinishProbe.onFinish,
    });
    finish_probe.looper = &looper;
    defer looper.deinit();

    try std.testing.expectError(
        error.Cancelled,
        looper.schedule(1, .{ .callback = noopTask }),
    );
    try looper.start();
    try looper.stop();

    try std.testing.expect(finish_probe.oob_was_cancelled.load(.acquire));
    try std.testing.expectError(error.Cancelled, looper.resumeReading(.link));
    try std.testing.expectError(
        error.Cancelled,
        looper.schedule(null, .{ .callback = noopTask }),
    );
    try std.testing.expectError(
        error.Cancelled,
        looper.performTask(.{ .callback = noopTask }),
    );
    try std.testing.expectError(error.Cancelled, looper.detach(.link));
    try std.testing.expectError(
        error.Cancelled,
        looper.writeQueued(&.{"discarded"}, .link),
    );
}

const FinishProbe = struct {
    looper: *Looper = undefined,
    oob_was_cancelled: AtomicBool = AtomicBool.init(false),

    fn onFinish(raw: ?*anyopaque, _: ?Looper.Failure) void {
        const self: *FinishProbe = @ptrCast(@alignCast(raw.?));
        self.looper.write(&.{"discarded"}, .link, true) catch |err| {
            self.oob_was_cancelled.store(err == error.Cancelled, .release);
        };
    }
};

test "side failure callback runs after the looper mutex is released" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try Pipe.init();
    defer pipe.deinit();
    var mock = MockIO{};
    var failure_probe = FailureProbe{};
    var looper = try initLooper(.{ .callback = noopFinish });
    failure_probe.looper = &looper;
    defer looper.deinit();
    try looper.start();

    try looper.attach(.{
        .pair = .{ .link = descriptor(pipe, &mock) },
        .on_failure = .{
            .context = &failure_probe,
            .callback = FailureProbe.onFailure,
        },
    });
    mock.fail_reads.store(true, .release);
    try pipe.makeReadable();

    waitUntil(&failure_probe.did_run);
    waitUntil(&mock.cleaned);
    try std.testing.expect(!failure_probe.was_attached.load(.acquire));
    try std.testing.expect(mock.cleaned.load(.acquire));
    try looper.stop();
}

test "out-of-band write returns the underlying I/O error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try Pipe.init();
    defer pipe.deinit();
    var mock = MockIO{};
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();
    try looper.attach(.{
        .pair = .{ .link = descriptor(pipe, &mock) },
    });
    mock.fail_writes.store(true, .release);

    const WriteTask = struct {
        fn run(raw: ?*anyopaque) anyerror!void {
            const current: *Looper = @ptrCast(@alignCast(raw.?));
            return current.write(&.{"packet"}, .link, true);
        }
    };
    try std.testing.expectError(
        error.EndOfStream,
        looper.performTask(.{ .context = &looper, .callback = WriteTask.run }),
    );

    try looper.detach(.link);
    try looper.stop();
}

const FailureProbe = struct {
    looper: *Looper = undefined,
    did_run: AtomicBool = AtomicBool.init(false),
    was_attached: AtomicBool = AtomicBool.init(true),

    fn onFailure(raw: ?*anyopaque, _: Looper.Failure) void {
        const self: *FailureProbe = @ptrCast(@alignCast(raw.?));
        self.was_attached.store(self.looper.isLinkAttached(), .release);
        self.did_run.store(true, .release);
    }
};

test "transform callback rejects synchronous looper calls" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try Pipe.init();
    defer pipe.deinit();
    var mock = MockIO{};
    var transform_probe = ReentrantTransform{};
    var other = try initLooper(.{ .callback = noopFinish });
    defer other.deinit();
    try other.start();
    var looper = try initLooper(.{ .callback = noopFinish });
    transform_probe.looper = &looper;
    transform_probe.other = &other;
    defer looper.deinit();
    try looper.start();

    try looper.attach(.{
        .pair = .{ .link = descriptor(pipe, &mock) },
        .transform_write = .{
            .context = &transform_probe,
            .callback = ReentrantTransform.transform,
        },
    });
    try looper.writeQueued(&.{"packet"}, .link);

    try std.testing.expect(transform_probe.was_rejected.load(.acquire));
    try std.testing.expect(transform_probe.cross_perform_was_rejected.load(.acquire));
    try looper.detach(.link);
    try looper.stop();
    try other.stop();
}

const ReentrantTransform = struct {
    looper: *Looper = undefined,
    other: *Looper = undefined,
    was_rejected: AtomicBool = AtomicBool.init(false),
    cross_perform_was_rejected: AtomicBool = AtomicBool.init(false),

    fn transform(raw: ?*anyopaque, packets: Looper.Packets) anyerror!Looper.Packets {
        const self: *ReentrantTransform = @ptrCast(@alignCast(raw.?));
        self.looper.detach(.link) catch |err| {
            self.was_rejected.store(err == error.ReentrantCall, .release);
        };
        self.other.performTask(.{ .callback = noopTask }) catch |err| {
            self.cross_perform_was_rejected.store(err == error.ReentrantCall, .release);
        };
        return packets;
    }
};

test "detach waits for an in-flight transform callback" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try Pipe.init();
    defer pipe.deinit();
    var mock = MockIO{};
    var transform_probe = BlockingTransform{};
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();

    try looper.attach(.{
        .pair = .{ .link = descriptor(pipe, &mock) },
        .transform_write = .{
            .context = &transform_probe,
            .callback = BlockingTransform.transform,
        },
    });

    var writer = WriteWorker{ .looper = &looper };
    var writer_thread = try std.Thread.spawn(.{}, WriteWorker.run, .{&writer});
    var writer_joined = false;
    defer if (!writer_joined) {
        transform_probe.release.store(true, .release);
        writer_thread.join();
    };
    waitUntil(&transform_probe.entered);

    var detacher = DetachWorker{ .looper = &looper };
    var detach_thread = try std.Thread.spawn(.{}, DetachWorker.run, .{&detacher});
    var detacher_joined = false;
    defer if (!detacher_joined) {
        transform_probe.release.store(true, .release);
        detach_thread.join();
    };
    waitUntil(&detacher.started);
    yieldRepeatedly();
    const detached_before_release = detacher.done.load(.acquire);

    transform_probe.release.store(true, .release);
    writer_thread.join();
    writer_joined = true;
    detach_thread.join();
    detacher_joined = true;

    try std.testing.expect(!detached_before_release);
    try std.testing.expect(writer.failure == null);
    try std.testing.expect(detacher.failure == null);
    try std.testing.expect(mock.cleaned.load(.acquire));
    try looper.stop();
}

const BlockingTransform = struct {
    entered: AtomicBool = AtomicBool.init(false),
    release: AtomicBool = AtomicBool.init(false),

    fn transform(raw: ?*anyopaque, packets: Looper.Packets) anyerror!Looper.Packets {
        const self: *BlockingTransform = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .release);
        waitUntil(&self.release);
        return packets;
    }
};

const WriteWorker = struct {
    looper: *Looper,
    failure: ?anyerror = null,

    fn run(self: *WriteWorker) void {
        self.looper.writeQueued(&.{"packet"}, .link) catch |err| {
            self.failure = err;
        };
    }
};

const DetachWorker = struct {
    looper: *Looper,
    started: AtomicBool = AtomicBool.init(false),
    done: AtomicBool = AtomicBool.init(false),
    failure: ?Looper.DetachError = null,

    fn run(self: *DetachWorker) void {
        self.started.store(true, .release);
        self.looper.detach(.link) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
};

test "deinit cancels a detach queued during a running command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try Pipe.init();
    defer pipe.deinit();
    var mock = MockIO{};
    var blocking_task = BlockingTask{};
    var looper = try initLooper(.{ .callback = noopFinish });
    var needs_deinit = true;
    defer if (needs_deinit) looper.deinit();
    try looper.start();
    try looper.attach(.{
        .pair = .{ .link = descriptor(pipe, &mock) },
    });

    try looper.schedule(null, .{
        .context = &blocking_task,
        .callback = BlockingTask.run,
    });
    waitUntil(&blocking_task.entered);

    var detacher = DetachWorker{ .looper = &looper };
    var detach_thread = try std.Thread.spawn(.{}, DetachWorker.run, .{&detacher});
    var detacher_joined = false;
    defer if (!detacher_joined) {
        blocking_task.release.store(true, .release);
        detach_thread.join();
    };
    waitUntil(&detacher.started);
    yieldRepeatedly();

    var deinit_worker = DeinitWorker{ .looper = &looper };
    var deinit_thread = try std.Thread.spawn(.{}, DeinitWorker.run, .{&deinit_worker});
    needs_deinit = false;
    var deinit_joined = false;
    defer if (!deinit_joined) {
        blocking_task.release.store(true, .release);
        deinit_thread.join();
    };

    waitUntil(&detacher.done);
    detach_thread.join();
    detacher_joined = true;
    try std.testing.expect(detacher.failure.? == error.Cancelled);

    blocking_task.release.store(true, .release);
    deinit_thread.join();
    deinit_joined = true;

    try std.testing.expect(deinit_worker.done.load(.acquire));
    try std.testing.expect(mock.cleaned.load(.acquire));
}

test "deinit cancels a perform queued during a running command" {
    var blocking_task = BlockingTask{};
    var looper = try initLooper(.{ .callback = noopFinish });
    var needs_deinit = true;
    defer if (needs_deinit) looper.deinit();
    try looper.start();

    try looper.schedule(null, .{
        .context = &blocking_task,
        .callback = BlockingTask.run,
    });
    waitUntil(&blocking_task.entered);

    var worker = PerformWorker{ .looper = &looper };
    var worker_thread = try std.Thread.spawn(.{}, PerformWorker.run, .{&worker});
    var worker_joined = false;
    defer if (!worker_joined) {
        blocking_task.release.store(true, .release);
        worker_thread.join();
    };
    waitUntil(&worker.started);
    yieldRepeatedly();

    var deinit_worker = DeinitWorker{ .looper = &looper };
    var deinit_thread = try std.Thread.spawn(.{}, DeinitWorker.run, .{&deinit_worker});
    var deinit_joined = false;
    defer if (!deinit_joined) {
        blocking_task.release.store(true, .release);
        deinit_thread.join();
    };

    waitUntil(&worker.done);
    worker_thread.join();
    worker_joined = true;
    blocking_task.release.store(true, .release);
    deinit_thread.join();
    deinit_joined = true;
    needs_deinit = false;

    try std.testing.expect(worker.was_cancelled.load(.acquire));
    try std.testing.expect(deinit_worker.done.load(.acquire));
}

const BlockingTask = struct {
    entered: AtomicBool = AtomicBool.init(false),
    release: AtomicBool = AtomicBool.init(false),

    fn run(raw: ?*anyopaque) anyerror!void {
        const self: *BlockingTask = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .release);
        waitUntil(&self.release);
    }
};

const PerformWorker = struct {
    looper: *Looper,
    started: AtomicBool = AtomicBool.init(false),
    done: AtomicBool = AtomicBool.init(false),
    was_cancelled: AtomicBool = AtomicBool.init(false),
    failure: ?anyerror = null,

    fn run(self: *PerformWorker) void {
        self.started.store(true, .release);
        self.looper.performTask(.{ .callback = noopTask }) catch |err| {
            self.failure = err;
            self.was_cancelled.store(err == error.Cancelled, .release);
        };
        self.done.store(true, .release);
    }
};

const DeinitWorker = struct {
    looper: *Looper,
    done: AtomicBool = AtomicBool.init(false),

    fn run(self: *DeinitWorker) void {
        self.looper.deinit();
        self.done.store(true, .release);
    }
};
