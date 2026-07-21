// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c = @import("c.zig").api;
const errors = @import("errors.zig");
const DataPathDecryptedTuple = @import("data_path_decrypted_tuple.zig").DataPathDecryptedTuple;
const DataPathDecryptedAndParsedTuple = @import("data_path_decrypted_and_parsed_tuple.zig").DataPathDecryptedAndParsedTuple;
const data_path_protocol = @import("data_path_protocol.zig");
const DataPathProtocol = data_path_protocol.DataPathProtocol;
const DataPathDecryptResult = @import("data_path_decrypt_result.zig").DataPathDecryptResult;
const DataPathTestingProtocol = @import("data_path_testing_protocol.zig").DataPathTestingProtocol;

extern fn partout_openvpn_dp_mode_decrypt_and_parse(
    mode: *c.openvpn_dp_mode,
    buffer: *c.pp_zd,
    packet_id: *u32,
    header: *u8,
    keep_alive: *bool,
    source: [*c]const u8,
    source_length: usize,
    native_error: *c.openvpn_dp_error,
) ?*c.pp_zd;

/// C-backed OpenVPN data path.
///
/// `mode` ownership transfers to `create` on success and is ultimately
/// released by `destroy`. Cryptographic/framing transforms, replay-window
/// bookkeeping, and ping recognition delegate to the existing C routines;
/// this type only owns buffers and orchestrates packet batches.
pub const CDataPath = struct {
    allocator: std.mem.Allocator,
    mode: *c.openvpn_dp_mode,
    enc_buffer: *c.pp_zd,
    dec_buffer: *c.pp_zd,
    replay: *c.openvpn_replay,
    out_packet_id: u32 = 0,

    const resize_step: usize = 1024;
    const initial_buffer_size: usize = 64 * 1024;
    const max_packet_id: u32 = std.math.maxInt(u32) - 10 * 1024;

    pub fn create(
        allocator: std.mem.Allocator,
        mode: *c.openvpn_dp_mode,
        peer_id: u32,
    ) std.mem.Allocator.Error!*CDataPath {
        const self = try allocator.create(CDataPath);
        c.openvpn_dp_mode_set_peer_id(mode, peer_id);
        self.* = .{
            .allocator = allocator,
            .mode = mode,
            .enc_buffer = c.pp_zd_create(initial_buffer_size),
            .dec_buffer = c.pp_zd_create(initial_buffer_size),
            .replay = c.openvpn_replay_create(),
        };
        return self;
    }

    pub fn destroy(self: *CDataPath) void {
        const allocator = self.allocator;
        c.openvpn_replay_free(self.replay);
        c.openvpn_dp_mode_free(self.mode);
        c.pp_zd_free(self.enc_buffer);
        c.pp_zd_free(self.dec_buffer);
        allocator.destroy(self);
    }

    pub fn asProtocol(self: *CDataPath) DataPathProtocol {
        return .{ .ptr = self, .vtable = &data_path_vtable };
    }

    pub fn asTestingProtocol(self: *CDataPath) DataPathTestingProtocol {
        return .{
            .data_path = self.asProtocol(),
            .testing_vtable = &testing_vtable,
        };
    }

    pub fn encryptPackets(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
        key: u8,
    ) anyerror![][]u8 {
        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |packet| allocator.free(packet);
            result.deinit(allocator);
        }
        try result.ensureTotalCapacity(allocator, packets.len);
        for (packets) |packet| {
            self.out_packet_id = std.math.add(u32, self.out_packet_id, 1) catch
                return error.DataPathOverflow;
            const encrypted = try self.assembleAndEncrypt(
                allocator,
                packet,
                key,
                self.out_packet_id,
            );
            result.appendAssumeCapacity(encrypted);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn decryptPackets(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror!DataPathDecryptResult {
        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |packet| allocator.free(packet);
            result.deinit(allocator);
        }
        try result.ensureTotalCapacity(allocator, packets.len);
        var keep_alive = false;
        for (packets) |packet| {
            var tuple = try self.decryptAndParse(allocator, packet);
            if (tuple.packet_id > max_packet_id) {
                tuple.deinit(allocator);
                return error.DataPathOverflow;
            }
            if (c.openvpn_replay_is_replayed(self.replay, tuple.packet_id)) {
                tuple.deinit(allocator);
                continue;
            }
            if (tuple.is_keep_alive) {
                keep_alive = true;
                tuple.deinit(allocator);
                continue;
            }
            result.appendAssumeCapacity(tuple.data);
            tuple.data = @constCast(&[_]u8{});
        }
        return .{
            .packets = try result.toOwnedSlice(allocator),
            .keep_alive = keep_alive,
        };
    }

    pub fn assemble(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        packet_id: u32,
        payload: []const u8,
    ) anyerror![]u8 {
        const capacity = c.openvpn_dp_mode_assemble_capacity(self.mode, payload.len);
        self.resize(self.enc_buffer, capacity);
        const length = c.openvpn_dp_mode_assemble(
            self.mode,
            packet_id,
            self.enc_buffer,
            payload.ptr,
            payload.len,
        );
        return allocator.dupe(u8, self.enc_buffer.*.bytes[0..length]);
    }

    pub fn encrypt(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        key: u8,
        packet_id: u32,
        assembled: []const u8,
    ) anyerror![]u8 {
        const capacity = c.openvpn_dp_mode_encrypt_capacity(self.mode, assembled.len);
        self.resize(self.enc_buffer, capacity);
        var native_error = emptyNativeError();
        const length = c.openvpn_dp_mode_encrypt(
            self.mode,
            key,
            packet_id,
            self.enc_buffer,
            assembled.ptr,
            assembled.len,
            &native_error,
        );
        if (length == 0) return nativeError(native_error);
        return allocator.dupe(u8, self.enc_buffer.*.bytes[0..length]);
    }

    pub fn assembleAndEncrypt(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
        key: u8,
        packet_id: u32,
    ) anyerror![]u8 {
        const capacity = c.openvpn_dp_mode_assemble_and_encrypt_capacity(self.mode, packet.len);
        self.resize(self.enc_buffer, capacity);
        var native_error = emptyNativeError();
        const data = c.openvpn_dp_mode_assemble_and_encrypt(
            self.mode,
            key,
            packet_id,
            self.enc_buffer,
            packet.ptr,
            packet.len,
            &native_error,
        ) orelse return nativeError(native_error);
        defer c.pp_zd_free(data);
        return allocator.dupe(u8, data.*.bytes[0..data.*.length]);
    }

    pub fn decrypt(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedTuple {
        self.resize(self.dec_buffer, packet.len);
        var packet_id: u32 = 0;
        var native_error = emptyNativeError();
        const length = c.openvpn_dp_mode_decrypt(
            self.mode,
            self.dec_buffer,
            &packet_id,
            packet.ptr,
            packet.len,
            &native_error,
        );
        if (length == 0) return nativeError(native_error);
        return .init(
            packet_id,
            try allocator.dupe(u8, self.dec_buffer.*.bytes[0..length]),
        );
    }

    pub fn parse(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        decrypted: []const u8,
        header: *u8,
    ) anyerror![]u8 {
        const input = try allocator.dupe(u8, decrypted);
        defer allocator.free(input);
        self.resize(self.dec_buffer, input.len);
        var native_error = emptyNativeError();
        const length = c.openvpn_dp_mode_parse(
            self.mode,
            self.dec_buffer,
            header,
            input.ptr,
            input.len,
            &native_error,
        );
        if (length == 0) return nativeError(native_error);
        return allocator.dupe(u8, self.dec_buffer.*.bytes[0..length]);
    }

    pub fn decryptAndParse(
        self: *CDataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedAndParsedTuple {
        self.resize(self.dec_buffer, packet.len);
        var packet_id: u32 = 0;
        var header: u8 = 0;
        var keep_alive = false;
        var native_error = emptyNativeError();
        const data = partout_openvpn_dp_mode_decrypt_and_parse(
            self.mode,
            self.dec_buffer,
            &packet_id,
            &header,
            &keep_alive,
            packet.ptr,
            packet.len,
            &native_error,
        ) orelse return nativeError(native_error);
        defer c.pp_zd_free(data);
        return .init(
            packet_id,
            header,
            keep_alive,
            try allocator.dupe(u8, data.*.bytes[0..data.*.length]),
        );
    }

    fn resize(_: *CDataPath, buffer: *c.pp_zd, count: usize) void {
        if (buffer.*.length >= count) return;
        const new_count = std.mem.alignForward(usize, count, resize_step);
        c.pp_zd_resize(buffer, new_count);
    }

    fn emptyNativeError() c.openvpn_dp_error {
        return .{
            .dp_code = c.OpenVPNDataPathErrorNone,
            .crypto_code = c.PPCryptoErrorNone,
        };
    }

    fn nativeError(native: c.openvpn_dp_error) anyerror {
        if (native.dp_code == c.OpenVPNDataPathErrorNone) return error.DataPathFailure;
        return errors.CDataPathError.fromNative(native).toError();
    }

    const data_path_vtable = DataPathProtocol.VTable{
        .encrypt = protocolEncrypt,
        .decrypt = protocolDecrypt,
        .deinit = protocolDeinit,
    };

    const testing_vtable = DataPathTestingProtocol.TestingVTable{
        .assemble = testingAssemble,
        .encrypt = testingEncrypt,
        .assemble_and_encrypt = testingAssembleAndEncrypt,
        .decrypt = testingDecrypt,
        .parse = testingParse,
        .decrypt_and_parse = testingDecryptAndParse,
    };

    fn cast(pointer: *anyopaque) *CDataPath {
        return @ptrCast(@alignCast(pointer));
    }

    fn protocolEncrypt(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
        key: u8,
    ) anyerror![][]u8 {
        return cast(pointer).encryptPackets(allocator, packets, key);
    }

    fn protocolDecrypt(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror!DataPathDecryptResult {
        return cast(pointer).decryptPackets(allocator, packets);
    }

    fn protocolDeinit(pointer: *anyopaque) void {
        cast(pointer).destroy();
    }

    fn testingAssemble(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        packet_id: u32,
        payload: []const u8,
    ) anyerror![]u8 {
        return cast(pointer).assemble(allocator, packet_id, payload);
    }

    fn testingEncrypt(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        key: u8,
        packet_id: u32,
        assembled: []const u8,
    ) anyerror![]u8 {
        return cast(pointer).encrypt(allocator, key, packet_id, assembled);
    }

    fn testingAssembleAndEncrypt(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        packet: []const u8,
        key: u8,
        packet_id: u32,
    ) anyerror![]u8 {
        return cast(pointer).assembleAndEncrypt(allocator, packet, key, packet_id);
    }

    fn testingDecrypt(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedTuple {
        return cast(pointer).decrypt(allocator, packet);
    }

    fn testingParse(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        decrypted: []const u8,
        header: *u8,
    ) anyerror![]u8 {
        return cast(pointer).parse(allocator, decrypted, header);
    }

    fn testingDecryptAndParse(
        pointer: *anyopaque,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedAndParsedTuple {
        return cast(pointer).decryptAndParse(allocator, packet);
    }
};

test "CDataPath mock round-trips individual, compound, and bulk packets" {
    const allocator = std.testing.allocator;
    const peer_id: u32 = 0x01;
    const key: u8 = 0x02;
    const packet_id: u32 = 0x1020;
    const payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    const mode = c.openvpn_dp_mode_ad_create_mock(c.OpenVPNCompressionFramingDisabled);
    const data_path = try CDataPath.create(allocator, mode, peer_id);
    defer data_path.destroy();

    const assembled = try data_path.assemble(allocator, packet_id, &payload);
    defer allocator.free(assembled);
    const encrypted = try data_path.encrypt(allocator, key, packet_id, assembled);
    defer allocator.free(encrypted);
    var decrypted = try data_path.decrypt(allocator, encrypted);
    defer decrypted.deinit(allocator);
    try std.testing.expectEqual(packet_id, decrypted.packet_id);
    try std.testing.expectEqualSlices(u8, assembled, decrypted.data);
    var header: u8 = 0;
    const parsed = try data_path.parse(allocator, decrypted.data, &header);
    defer allocator.free(parsed);
    try std.testing.expectEqualSlices(u8, &payload, parsed);

    const compound = try data_path.assembleAndEncrypt(
        allocator,
        &payload,
        key,
        packet_id,
    );
    defer allocator.free(compound);
    var compound_result = try data_path.decryptAndParse(allocator, compound);
    defer compound_result.deinit(allocator);
    try std.testing.expectEqual(packet_id, compound_result.packet_id);
    try std.testing.expectEqualSlices(u8, &payload, compound_result.data);

    const packets = [_][]const u8{&payload};
    const encrypted_packets = try data_path.encryptPackets(allocator, &packets, key);
    defer data_path_protocol.freePackets(allocator, encrypted_packets);
    var decrypted_packets = try data_path.decryptPackets(allocator, encrypted_packets);
    defer decrypted_packets.deinit(allocator);
    try std.testing.expect(!decrypted_packets.keep_alive);
    try std.testing.expectEqual(@as(usize, 1), decrypted_packets.packets.len);
    try std.testing.expectEqualSlices(u8, &payload, decrypted_packets.packets[0]);
}
