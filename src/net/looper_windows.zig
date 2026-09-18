// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io_common.zig");
const io_c = io.io_c;
const log = core.logging;

pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    options: helpers.Options,

    // Worker thread.
    actor: *Actor,

    pub fn create(allocator: std.mem.Allocator, options: helpers.Options) helpers.InitError!*WindowsLooper {
        const self = try allocator.create(WindowsLooper);
        errdefer allocator.destroy(self);
        const actor = Actor.create(allocator, self) catch return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .actor = actor,
            .options = options,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.actor.destroy();
        self.allocator.destroy(self);
    }

    pub fn start(_: *WindowsLooper) helpers.StartError!void {}

    pub fn stop(_: *WindowsLooper) helpers.StopError!void {}

    pub fn isOnQueue(self: *WindowsLooper) bool {
        return self.actor.isOnQueue();
    }

    pub fn perform(
        self: *WindowsLooper,
        comptime Result: type,
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque) anyerror!Result,
    ) anyerror!Result {
        var task = Task(Result){ .context = context, .callback = callback };
        return self.actor.perform(Result, .{ .perform = &task });
    }

    pub fn performTask(self: *WindowsLooper, task: helpers.Task) anyerror!void {
        return self.perform(void, task.context, task.callback);
    }

    pub fn scheduleReplacing(
        _: *WindowsLooper,
        _: *helpers.Timer,
        _: u64,
        _: helpers.TimedTask,
    ) helpers.ScheduleTimerError!void {
        // FIXME: ###, Implement timers
        return error.LooperUnavailable;
    }

    pub fn cancelTimer(_: *WindowsLooper, _: *helpers.Timer) void {
        // FIXME: ###, Implement timers
    }

    pub fn attach(self: *WindowsLooper, arguments: helpers.AttachArguments) helpers.AttachError!void {
        _ = self;
        _ = arguments;
        // if (udp) {
        //     udp.MessageReceived() {
        //         self.actor.schedule(side.onLinkRead)
        //     }
        // } else if tcp {
        //     tcp.readAsync(onComplete: onTCP)
        // }
        return error.LooperUnavailable;
    }

    pub fn detach(self: *WindowsLooper, side: io.Side) helpers.DetachError!void {
        _ = self;
        _ = side;
        return error.LooperUnavailable;
    }

    pub fn isLinkAttached(_: *WindowsLooper) bool {
        return false;
    }

    pub fn isTunAttached(_: *WindowsLooper) bool {
        return false;
    }

    pub fn resumeReading(_: *WindowsLooper, _: io.Side) helpers.ResumeReadingError!void {
        return error.LooperUnavailable;
    }

    pub fn writeQueued(
        _: *WindowsLooper,
        _: helpers.Packets,
        _: io.Side,
    ) helpers.WriteError!void {
        // FIXME: ###, Implement socket write
        return error.LooperUnavailable;
    }

    pub fn writeOutOfBand(
        _: *WindowsLooper,
        _: helpers.Packets,
        _: io.Side,
    ) helpers.WriteOOBError!void {
        // FIXME: ###, Implement socket write
        return error.LooperUnavailable;
    }

    //#region Event loop

    fn onTCP(self: *WindowsLooper) void {
        _ = self;
        // self.actor.schedule(processReadPackets);
    }

    fn processReadPackets(self: *const WindowsLooper) void {
        _ = self;
        // side.onLinkRead();
        // tcp.readAsync(onComplete: onTCP);
    }

    //#endregion

    //#region Actor interface

    const Actor = core.actor.ActorWithFinish(
        WindowsLooper,
        Message,
        anyerror, // FIXME: ###, Use specific error type
        handleMessage,
        actorDidFinish,
    );

    fn Task(comptime Result: type) type {
        return struct {
            context: ?*anyopaque,
            callback: *const fn (?*anyopaque) anyerror!Result,
        };
    }

    const Message = union(enum) {
        // Stack-backed Task(Result), valid until the synchronous call completes.
        perform: *anyopaque,
    };

    fn handleMessage(_: *WindowsLooper, comptime Result: type, message: Message) !Result {
        switch (message) {
            .perform => |raw_task| {
                const task: *const Task(Result) = @ptrCast(@alignCast(raw_task));
                return task.callback(task.context);
            },
        }
    }

    fn actorDidFinish(self: *WindowsLooper) void {
        _ = self;
    }

    //#endregion
};
