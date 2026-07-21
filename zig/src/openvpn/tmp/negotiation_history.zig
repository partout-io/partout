// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const PushReply = @import("push_reply.zig").PushReply;

pub const NegotiationHistory = struct {
    push_reply: PushReply,

    pub fn init(push_reply: *PushReply) NegotiationHistory {
        const moved = push_reply.*;
        push_reply.* = undefined;
        return .{ .push_reply = moved };
    }

    pub fn clone(self: NegotiationHistory, allocator: std.mem.Allocator) anyerror!NegotiationHistory {
        return .{ .push_reply = try self.push_reply.clone(allocator) };
    }

    pub fn deinit(self: *NegotiationHistory, allocator: std.mem.Allocator) void {
        self.push_reply.deinit(allocator);
        self.* = undefined;
    }
};

test "negotiation history deep-clones push options" {
    var reply = (try PushReply.parse(std.testing.allocator, "PUSH_REPLY,ping 10")).?;
    var history = NegotiationHistory.init(&reply);
    defer history.deinit(std.testing.allocator);
    var copy = try history.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f64, 10), copy.push_reply.options.keep_alive_interval);
}
