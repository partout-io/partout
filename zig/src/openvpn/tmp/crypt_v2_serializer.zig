// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("../../core/exports.zig").api;
const c = @import("c.zig").api;
const CControlPacket = @import("c_control_packet.zig").CControlPacket;
const ControlChannelSerializer = @import("control_channel_serializer.zig").ControlChannelSerializer;
const CryptSerializer = @import("crypt_serializer.zig").CryptSerializer;

pub const CryptV2Serializer = struct {
    wrapped_key: []u8,
    serializer: CryptSerializer,

    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_enc_fnt,
        key: api.OpenVPNStaticKey,
        wrapped_key: api.SecureData,
    ) anyerror!CryptV2Serializer {
        const decoded = try wrapped_key.bytesAlloc(allocator);
        errdefer {
            @memset(decoded, 0);
            allocator.free(decoded);
        }
        return .{
            .wrapped_key = decoded,
            .serializer = try CryptSerializer.init(allocator, fnt, key),
        };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_enc_fnt,
        key: api.OpenVPNStaticKey,
        wrapped_key: api.SecureData,
    ) anyerror!ControlChannelSerializer {
        const self = try allocator.create(CryptV2Serializer);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, fnt, key, wrapped_key);
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *CryptV2Serializer, allocator: std.mem.Allocator) void {
        self.serializer.deinit();
        @memset(self.wrapped_key, 0);
        allocator.free(self.wrapped_key);
        self.* = undefined;
    }

    pub fn reset(self: *CryptV2Serializer) void {
        self.serializer.reset();
    }

    pub fn serialize(
        self: *CryptV2Serializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
    ) anyerror![]u8 {
        var data = try self.serializer.serialize(allocator, packet);
        errdefer allocator.free(data);
        switch (packet.code) {
            .hardResetClientV3, .controlWkcV1 => {
                const old_len = data.len;
                data = try allocator.realloc(data, old_len + self.wrapped_key.len);
                @memcpy(data[old_len..], self.wrapped_key);
            },
            else => {},
        }
        return data;
    }

    pub fn deserialize(
        self: *CryptV2Serializer,
        allocator: std.mem.Allocator,
        data: []const u8,
        start: usize,
        end: ?usize,
    ) anyerror!CControlPacket {
        return self.serializer.deserialize(allocator, data, start, end);
    }

    fn erasedReset(raw: *anyopaque) void {
        reset(@ptrCast(@alignCast(raw)));
    }
    fn erasedSerialize(raw: *anyopaque, allocator: std.mem.Allocator, packet: *const CControlPacket) anyerror![]u8 {
        return serialize(@ptrCast(@alignCast(raw)), allocator, packet);
    }
    fn erasedDeserialize(raw: *anyopaque, allocator: std.mem.Allocator, data: []const u8, start: usize, end: ?usize) anyerror!CControlPacket {
        return deserialize(@ptrCast(@alignCast(raw)), allocator, data, start, end);
    }
    fn erasedDestroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *CryptV2Serializer = @ptrCast(@alignCast(raw));
        self.deinit(allocator);
        allocator.destroy(self);
    }
    const vtable: ControlChannelSerializer.VTable = .{
        .reset = erasedReset,
        .serialize = erasedSerialize,
        .deserialize = erasedDeserialize,
        .destroy = erasedDestroy,
    };
};

test "tls-crypt-v2 appends the wrapped key only to WKC opcodes" {
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var secure_key = try api.SecureData.initBytesAlloc(std.testing.allocator, &key_bytes);
    defer secure_key.deinit(std.testing.allocator);
    const wrapped_bytes = [_]u8{ 0xfa, 0xce, 0xb0, 0x0c };
    var secure_wrapped = try api.SecureData.initBytesAlloc(std.testing.allocator, &wrapped_bytes);
    defer secure_wrapped.deinit(std.testing.allocator);
    const key = api.OpenVPNStaticKey{ .data = secure_key, .dir = .client };
    const functions = c.pp_crypto_fnt_mock();
    var serializer = try CryptV2Serializer.init(
        std.testing.allocator,
        functions.enc,
        key,
        secure_wrapped,
    );
    defer serializer.deinit(std.testing.allocator);

    const session_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var wkc = try CControlPacket.init(.hardResetClientV3, 0, &session_id, 0, null, null, null);
    defer wkc.deinit();
    const wrapped = try serializer.serialize(std.testing.allocator, &wkc);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expect(std.mem.endsWith(u8, wrapped, &wrapped_bytes));

    var ordinary = try CControlPacket.init(.controlV1, 0, &session_id, 1, null, null, null);
    defer ordinary.deinit();
    const unwrapped = try serializer.serialize(std.testing.allocator, &ordinary);
    defer std.testing.allocator.free(unwrapped);
    try std.testing.expect(!std.mem.endsWith(u8, unwrapped, &wrapped_bytes));
}
