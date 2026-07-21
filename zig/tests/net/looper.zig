// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");
const io = source.net_io;

const Looper = source.net_looper.Looper;
const AtomicBool = std.atomic.Value(bool);

const libc = struct {
    extern "c" fn close(fd: std.c.fd_t) c_int;
};

fn waitUntil(value: *const AtomicBool) void {
    while (!value.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

fn settleScheduler() void {
    for (0..1000) |_| {
        std.Thread.yield() catch {};
    }
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

    fn write(_: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
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

test "perform completion is released before later commands finish" {
    var first_task = BlockingTask{};
    var second_task = BlockingTask{};
    var looper = try initLooper(.{ .callback = noopFinish });
    defer looper.deinit();
    try looper.start();

    // Hold the actor so perform and the second task land in the same detached
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
    settleScheduler();

    try looper.schedule(null, .{
        .context = &second_task,
        .callback = BlockingTask.run,
    });
    first_task.release.store(true, .release);
    waitUntil(&second_task.entered);
    settleScheduler();
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
    settleScheduler();
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
    failure: ?anyerror = null,

    fn run(self: *DetachWorker) void {
        self.started.store(true, .release);
        self.looper.detach(.link) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
};

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
    settleScheduler();

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
