// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const CControlPacket = @import("c_control_packet.zig").CControlPacket;

/// Type-erased owning serializer interface.
pub const ControlChannelSerializer = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reset: *const fn (*anyopaque) void,
        serialize: *const fn (*anyopaque, std.mem.Allocator, *const CControlPacket) anyerror![]u8,
        deserialize: *const fn (*anyopaque, std.mem.Allocator, []const u8, usize, ?usize) anyerror!CControlPacket,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn deinit(self: *ControlChannelSerializer, allocator: std.mem.Allocator) void {
        if (self.ptr) |ptr| self.vtable.destroy(ptr, allocator);
        self.ptr = null;
    }

    pub fn move(self: *ControlChannelSerializer) ControlChannelSerializer {
        const result = self.*;
        self.ptr = null;
        return result;
    }

    pub fn reset(self: *ControlChannelSerializer) void {
        self.vtable.reset(self.ptr orelse @panic("use of moved ControlChannelSerializer"));
    }

    pub fn serialize(
        self: *ControlChannelSerializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
    ) anyerror![]u8 {
        return self.vtable.serialize(self.ptr orelse @panic("use of moved ControlChannelSerializer"), allocator, packet);
    }

    pub fn deserialize(
        self: *ControlChannelSerializer,
        allocator: std.mem.Allocator,
        data: []const u8,
        start: usize,
        end: ?usize,
    ) anyerror!CControlPacket {
        return self.vtable.deserialize(
            self.ptr orelse @panic("use of moved ControlChannelSerializer"),
            allocator,
            data,
            start,
            end,
        );
    }
};

test "serializer interface is move-only by convention" {
    const Dummy = struct {
        fn reset(_: *anyopaque) void {}
        fn serialize(_: *anyopaque, allocator: std.mem.Allocator, _: *const CControlPacket) anyerror![]u8 {
            return allocator.alloc(u8, 0);
        }
        fn deserialize(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize, _: ?usize) anyerror!CControlPacket {
            return error.Unused;
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
        const vtable: ControlChannelSerializer.VTable = .{
            .reset = reset,
            .serialize = serialize,
            .deserialize = deserialize,
            .destroy = destroy,
        };
    };
    var byte: u8 = 0;
    var serializer = ControlChannelSerializer{ .ptr = &byte, .vtable = &Dummy.vtable };
    var moved = serializer.move();
    defer moved.deinit(std.testing.allocator);
    try std.testing.expect(serializer.ptr == null);
}
