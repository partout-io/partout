// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const c_common = @import("../../c/exports.zig").common;
const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;
const PRF = @import("auth.zig").PRF;
const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
const CryptoKeysBridge = @import("crypto_keys_bridge.zig").CryptoKeysBridge;
const errors = @import("errors.zig");
const LinkProcessor = @import("processing.zig").LinkProcessor;
const PRNG = @import("prng.zig").PRNG;
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

const api = core.api;

pub const DataConstants = struct {
    pub const prng_seed_length: usize = 64;
    pub const aead_tag_length: usize = 16;
    pub const aead_id_length: usize = c.OpenVPNPacketIdLength;
    pub const ping_string = [_]u8{
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48,
    };
    pub const uses_replay_protection = true;
};

test "OpenVPN ping payload is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), DataConstants.ping_string.len);
}

pub const DataPathParameters = struct {
    fnt: c_crypto.pp_crypto_enc_fnt,
    cipher: ?api.OpenVPNCipher,
    digest: ?api.OpenVPNDigest,
    compression_framing: api.OpenVPNCompressionFraming,
    compression_algorithm: api.OpenVPNCompressionAlgorithm,
    peer_id: ?u32,
};

pub const DataPathDecryptedTuple = struct {
    packet_id: u32,
    data: []u8,

    pub fn init(packet_id: u32, data: []u8) DataPathDecryptedTuple {
        return .{ .packet_id = packet_id, .data = data };
    }

    pub fn deinit(self: *DataPathDecryptedTuple, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const DataPathDecryptedAndParsedTuple = struct {
    packet_id: u32,
    header: u8,
    is_keep_alive: bool,
    data: []u8,

    pub fn init(
        packet_id: u32,
        header: u8,
        is_keep_alive: bool,
        data: []u8,
    ) DataPathDecryptedAndParsedTuple {
        return .{
            .packet_id = packet_id,
            .header = header,
            .is_keep_alive = is_keep_alive,
            .data = data,
        };
    }

    pub fn deinit(
        self: *DataPathDecryptedAndParsedTuple,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Owning Zig representation of Swift's bulk-decrypt result tuple.
pub const DataPathDecryptResult = struct {
    packets: [][]u8,
    keep_alive: bool,

    pub fn deinit(self: *DataPathDecryptResult, allocator: std.mem.Allocator) void {
        for (self.packets) |packet| allocator.free(packet);
        allocator.free(self.packets);
        self.* = undefined;
    }
};

/// C-backed OpenVPN data path.
///
/// `mode` ownership transfers to `create` on success and is ultimately
/// released by `destroy`. Cryptographic/framing transforms, replay-window
/// bookkeeping, and ping recognition delegate to the existing C routines;
/// this type only owns buffers and orchestrates packet batches.
pub const DataPath = struct {
    allocator: std.mem.Allocator,
    mode: *c.openvpn_dp_mode,
    enc_buffer: *c_common.pp_zd,
    dec_buffer: *c_common.pp_zd,
    replay: *c.openvpn_replay,
    out_packet_id: u32 = 0,

    const resize_step: usize = 1024;
    const initial_buffer_size: usize = 64 * 1024;
    const max_packet_id: u32 = std.math.maxInt(u32) - 10 * 1024;

    pub fn create(
        allocator: std.mem.Allocator,
        mode: *c.openvpn_dp_mode,
        peer_id: u32,
    ) std.mem.Allocator.Error!*DataPath {
        const self = try allocator.create(DataPath);
        c.openvpn_dp_mode_set_peer_id(mode, peer_id);
        self.* = .{
            .allocator = allocator,
            .mode = mode,
            .enc_buffer = c_common.pp_zd_create(initial_buffer_size),
            .dec_buffer = c_common.pp_zd_create(initial_buffer_size),
            .replay = c.openvpn_replay_create(),
        };
        return self;
    }

    pub fn destroy(self: *DataPath) void {
        const allocator = self.allocator;
        c.openvpn_replay_free(self.replay);
        c.openvpn_dp_mode_free(self.mode);
        c_common.pp_zd_free(self.enc_buffer);
        c_common.pp_zd_free(self.dec_buffer);
        allocator.destroy(self);
    }

    pub fn encryptPackets(
        self: *DataPath,
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
                return error.Recoverable;
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
        self: *DataPath,
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
                return error.Recoverable;
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
        self: *DataPath,
        allocator: std.mem.Allocator,
        packet_id: u32,
        payload: []const u8,
    ) anyerror![]u8 {
        const capacity = c.openvpn_dp_mode_assemble_capacity(self.mode, payload.len);
        self.resize(self.enc_buffer, capacity);
        const length = c.openvpn_dp_mode_assemble(
            self.mode,
            packet_id,
            @ptrCast(self.enc_buffer),
            payload.ptr,
            payload.len,
        );
        return allocator.dupe(u8, self.enc_buffer.*.bytes[0..length]);
    }

    pub fn encrypt(
        self: *DataPath,
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
            @ptrCast(self.enc_buffer),
            assembled.ptr,
            assembled.len,
            &native_error,
        );
        if (length == 0) return nativeError(native_error);
        return allocator.dupe(u8, self.enc_buffer.*.bytes[0..length]);
    }

    pub fn assembleAndEncrypt(
        self: *DataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
        key: u8,
        packet_id: u32,
    ) anyerror![]u8 {
        const capacity = c.openvpn_dp_mode_assemble_and_encrypt_capacity(self.mode, packet.len);
        self.resize(self.enc_buffer, capacity);
        var native_error = emptyNativeError();
        const data: *c_common.pp_zd = @ptrCast(c.openvpn_dp_mode_assemble_and_encrypt(
            self.mode,
            key,
            packet_id,
            @ptrCast(self.enc_buffer),
            packet.ptr,
            packet.len,
            &native_error,
        ) orelse return nativeError(native_error));
        defer c_common.pp_zd_free(data);
        return allocator.dupe(u8, data.*.bytes[0..data.*.length]);
    }

    pub fn decrypt(
        self: *DataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedTuple {
        self.resize(self.dec_buffer, packet.len);
        var packet_id: u32 = 0;
        var native_error = emptyNativeError();
        const length = c.openvpn_dp_mode_decrypt(
            self.mode,
            @ptrCast(self.dec_buffer),
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
        self: *DataPath,
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
            @ptrCast(self.dec_buffer),
            header,
            input.ptr,
            input.len,
            &native_error,
        );
        if (length == 0) return nativeError(native_error);
        return allocator.dupe(u8, self.dec_buffer.*.bytes[0..length]);
    }

    pub fn decryptAndParse(
        self: *DataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedAndParsedTuple {
        self.resize(self.dec_buffer, packet.len);
        var packet_id: u32 = 0;
        var header: u8 = 0;
        var keep_alive = false;
        var native_error = emptyNativeError();
        const data: *c_common.pp_zd = @ptrCast(c.openvpn_dp_mode_decrypt_and_parse(
            self.mode,
            @ptrCast(self.dec_buffer),
            &packet_id,
            &header,
            &keep_alive,
            packet.ptr,
            packet.len,
            &native_error,
        ) orelse return nativeError(native_error));
        defer c_common.pp_zd_free(data);
        return .init(
            packet_id,
            header,
            keep_alive,
            try allocator.dupe(u8, data.*.bytes[0..data.*.length]),
        );
    }

    fn resize(_: *DataPath, buffer: *c_common.pp_zd, count: usize) void {
        if (buffer.*.length >= count) return;
        const new_count = std.mem.alignForward(usize, count, resize_step);
        c_common.pp_zd_resize(buffer, new_count);
    }

    fn emptyNativeError() c.openvpn_dp_error {
        return .{
            .dp_code = c.OpenVPNDataPathErrorNone,
            .crypto_code = c_crypto.PPCryptoErrorNone,
        };
    }

    fn nativeError(native: c.openvpn_dp_error) anyerror {
        if (native.dp_code == c.OpenVPNDataPathErrorNone) return error.DataPathFailure;
        return errors.dataPathError(native);
    }
};

test "DataPath mock round-trips individual, compound, and bulk packets" {
    const allocator = std.testing.allocator;
    const peer_id: u32 = 0x01;
    const key: u8 = 0x02;
    const packet_id: u32 = 0x1020;
    const payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    const mode = c.openvpn_dp_mode_ad_create_mock(c.OpenVPNCompressionFramingDisabled);
    const data_path = try DataPath.create(allocator, mode, peer_id);
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
    defer freePackets(allocator, encrypted_packets);
    var decrypted_packets = try data_path.decryptPackets(allocator, encrypted_packets);
    defer decrypted_packets.deinit(allocator);
    try std.testing.expect(!decrypted_packets.keep_alive);
    try std.testing.expectEqual(@as(usize, 1), decrypted_packets.packets.len);
    try std.testing.expectEqualSlices(u8, &payload, decrypted_packets.packets[0]);
}

fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
    for (packets) |packet| allocator.free(packet);
    allocator.free(packets);
}

/// Owning facade over the concrete C-backed data path.
pub const DataPathWrapper = struct {
    pub const Parameters = DataPathParameters;

    data_path: *DataPath,

    pub fn init(data_path: *DataPath) DataPathWrapper {
        return .{ .data_path = data_path };
    }

    pub fn deinit(self: *DataPathWrapper) void {
        self.data_path.destroy();
        self.* = undefined;
    }

    pub fn encrypt(
        self: DataPathWrapper,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
        key: u8,
    ) anyerror![][]u8 {
        return self.data_path.encryptPackets(allocator, packets, key);
    }

    pub fn decrypt(
        self: DataPathWrapper,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror!DataPathDecryptResult {
        return self.data_path.decryptPackets(allocator, packets);
    }

    pub fn nativeWithPRF(
        allocator: std.mem.Allocator,
        parameters: DataPathParameters,
        prf: *const PRF,
        prng: PRNG,
    ) anyerror!DataPathWrapper {
        var seed = try prng.safeData(allocator, DataConstants.prng_seed_length);
        defer seed.deinit(allocator);
        return nativeWithSeed(allocator, parameters, prf, seed);
    }

    pub fn nativeWithSeed(
        allocator: std.mem.Allocator,
        parameters: DataPathParameters,
        prf: *const PRF,
        seed: ZeroingData,
    ) anyerror!DataPathWrapper {
        const init_seed = parameters.fnt.init_seed orelse return error.UnsupportedAlgorithm;
        _ = init_seed(seed.bytes.ptr, seed.bytes.len);
        var keys = try prf.derive(allocator);
        defer keys.deinit(allocator);
        return nativeWithKeys(allocator, parameters, &keys);
    }

    pub fn nativeWithKeys(
        allocator: std.mem.Allocator,
        parameters: DataPathParameters,
        keys: *const CryptoKeys,
    ) anyerror!DataPathWrapper {
        var bridge = try CryptoKeysBridge.init(allocator, keys);
        defer bridge.deinit();

        const framing = nativeFraming(parameters.compression_framing);
        const cipher_name = if (parameters.cipher) |cipher|
            try allocator.dupeZ(u8, cipher.raw())
        else
            null;
        defer if (cipher_name) |value| allocator.free(value);
        const digest_name = if (parameters.digest) |digest|
            try allocator.dupeZ(u8, digest.raw())
        else
            null;
        defer if (digest_name) |value| allocator.free(value);

        const mode: *c.openvpn_dp_mode = if (isAEAD(parameters.cipher)) blk: {
            const name = cipher_name orelse return error.UnsupportedAlgorithm;
            break :blk c.openvpn_dp_mode_ad_create_aead(
                @ptrCast(&parameters.fnt),
                name.ptr,
                DataConstants.aead_tag_length,
                DataConstants.aead_id_length,
                @ptrCast(bridge.native()),
                framing,
            ) orelse return error.UnsupportedAlgorithm;
        } else blk: {
            const digest = digest_name orelse return error.UnsupportedAlgorithm;
            break :blk c.openvpn_dp_mode_hmac_create_cbc(
                @ptrCast(&parameters.fnt),
                if (cipher_name) |value| value.ptr else null,
                digest.ptr,
                @ptrCast(bridge.native()),
                framing,
            ) orelse return if (cipher_name != null)
                error.UnsupportedAlgorithm
            else
                error.UnsupportedAlgorithm;
        };
        errdefer c.openvpn_dp_mode_free(mode);

        const implementation = try DataPath.create(
            allocator,
            mode,
            parameters.peer_id orelse c.OpenVPNPacketPeerIdDisabled,
        );
        return init(implementation);
    }

    pub fn nativeADMock(
        allocator: std.mem.Allocator,
        framing: api.OpenVPNCompressionFraming,
    ) std.mem.Allocator.Error!DataPathWrapper {
        const mode = c.openvpn_dp_mode_ad_create_mock(nativeFraming(framing));
        errdefer c.openvpn_dp_mode_free(mode);
        const implementation = try DataPath.create(
            allocator,
            mode,
            c.OpenVPNPacketPeerIdDisabled,
        );
        return init(implementation);
    }

    pub fn nativeHMACMock(
        allocator: std.mem.Allocator,
        framing: api.OpenVPNCompressionFraming,
    ) std.mem.Allocator.Error!DataPathWrapper {
        const mode = c.openvpn_dp_mode_hmac_create_mock(nativeFraming(framing));
        errdefer c.openvpn_dp_mode_free(mode);
        const implementation = try DataPath.create(
            allocator,
            mode,
            c.OpenVPNPacketPeerIdDisabled,
        );
        return init(implementation);
    }

    fn isAEAD(cipher: ?api.OpenVPNCipher) bool {
        const value = cipher orelse return false;
        return switch (value) {
            .aes128gcm, .aes192gcm, .aes256gcm => true,
            else => false,
        };
    }

    fn nativeFraming(value: api.OpenVPNCompressionFraming) c.openvpn_compression_framing {
        return switch (value) {
            .disabled => c.OpenVPNCompressionFramingDisabled,
            .compLZO => c.OpenVPNCompressionFramingCompLZO,
            .compress => c.OpenVPNCompressionFramingCompress,
            .compressV2 => c.OpenVPNCompressionFramingCompressV2,
        };
    }
};

/// Owns one negotiated OpenVPN data-path key slot.
pub const DataChannel = struct {
    allocator: std.mem.Allocator,
    key: u8,
    data_path: DataPathWrapper,

    /// `data_path` ownership transfers only when this function succeeds.
    pub fn create(
        allocator: std.mem.Allocator,
        key: u8,
        data_path: DataPathWrapper,
    ) std.mem.Allocator.Error!*DataChannel {
        const self = try allocator.create(DataChannel);
        self.* = .{
            .allocator = allocator,
            .key = key,
            .data_path = data_path,
        };
        return self;
    }

    pub fn destroy(self: *DataChannel) void {
        const allocator = self.allocator;
        self.data_path.deinit();
        allocator.destroy(self);
    }

    /// The caller owns the returned packet rows and outer slice.
    pub fn encrypt(
        self: *DataChannel,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror![][]u8 {
        return self.data_path.encrypt(allocator, packets, self.key);
    }

    /// The caller owns the returned packet rows and outer slice.
    pub fn decrypt(
        self: *DataChannel,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror![][]u8 {
        const result = try self.data_path.decrypt(allocator, packets);
        return result.packets;
    }
};

/// Encrypts/decrypts data-channel packets and moves them between LINK and TUN.
///
/// Every method is expected to execute on the owning session's looper thread.
/// In particular, timeout writes use the looper's out-of-band path, whose API
/// deliberately rejects calls from any other thread.
pub const DataLink = struct {
    allocator: std.mem.Allocator,
    looper: *net.Looper,
    link_processor: *LinkProcessor,
    context: ?*anyopaque,
    callbacks: Callbacks,

    pub const Callbacks = struct {
        data_channel: *const fn (?*anyopaque, u8) ?*DataChannel,
        report_inbound_data_count: *const fn (?*anyopaque, usize) void,
        report_outbound_data_count: *const fn (?*anyopaque, usize) void,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        looper: *net.Looper,
        link_processor: *LinkProcessor,
        context: ?*anyopaque,
        callbacks: Callbacks,
    ) DataLink {
        return .{
            .allocator = allocator,
            .looper = looper,
            .link_processor = link_processor,
            .context = context,
            .callbacks = callbacks,
        };
    }

    pub fn receive(
        self: *DataLink,
        packets: []const []const u8,
        key: u8,
    ) anyerror!void {
        self.receiveUnwrapped(packets, key) catch |err|
            return mapInboundError(err);
    }

    fn receiveUnwrapped(
        self: *DataLink,
        packets: []const []const u8,
        key: u8,
    ) anyerror!void {
        const channel = self.callbacks.data_channel(self.context, key) orelse return;
        const decrypted = try channel.decrypt(self.allocator, packets);
        defer DataLink.freePackets(self.allocator, decrypted);
        if (decrypted.len == 0) return;

        self.callbacks.report_inbound_data_count(
            self.context,
            flatCount(decrypted),
        );
        try self.looper.writeQueued(asConstPackets(decrypted), .tun);
    }

    pub fn send(
        self: *DataLink,
        packets: []const []const u8,
        key: u8,
        timeout_ms: ?u64,
    ) anyerror!void {
        const channel = self.callbacks.data_channel(self.context, key) orelse return;
        const encrypted = try channel.encrypt(self.allocator, packets);
        defer DataLink.freePackets(self.allocator, encrypted);
        if (encrypted.len == 0) return;

        self.callbacks.report_outbound_data_count(
            self.context,
            flatCount(encrypted),
        );

        var processed = try self.link_processor.processOutbound(asConstPackets(encrypted));
        defer processed.deinit();

        const timeout = timeout_ms orelse {
            try self.looper.writeQueued(processed.packets(), .link);
            return;
        };
        if (!self.looper.isOnQueue()) return error.ReentrantCall;

        const start = core.concurrency.monotonicNs();
        const deadline = start +| timeout *| @as(u64, std.time.ns_per_ms);
        var last_error: ?anyerror = null;
        while (true) {
            self.looper.write(processed.packets(), .link, true) catch |err| {
                last_error = err;
                if (core.concurrency.monotonicNs() < deadline) continue;
                return last_error orelse error.Timeout;
            };
            return;
        }
    }

    fn flatCount(packets: []const []u8) usize {
        var result: usize = 0;
        for (packets) |packet| result +|= packet.len;
        return result;
    }

    fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
        for (packets) |packet| allocator.free(packet);
        allocator.free(packets);
    }

    fn asConstPackets(packets: []const []u8) []const []const u8 {
        // Slice mutability is not part of the packet identity. The returned
        // view borrows the exact same rows and is used only for synchronous
        // processing/copying by PacketProcessor and Looper.
        return @ptrCast(packets);
    }

    fn mapInboundError(err: anyerror) anyerror {
        // Native failures retain only the category reported to the daemon.
        // Allocation, looper, and other inbound failures are recoverable.
        return switch (err) {
            error.CryptoFailure,
            error.CompressionMismatch,
            error.DataPathFailure,
            => err,
            else => error.Recoverable,
        };
    }
};

test "DataLink declarations are semantically analyzed" {
    std.testing.refAllDecls(DataLink);
}

test "DataLink preserves only reportable inbound failure categories" {
    try std.testing.expectEqual(error.CryptoFailure, DataLink.mapInboundError(error.CryptoFailure));
    try std.testing.expectEqual(error.CompressionMismatch, DataLink.mapInboundError(error.CompressionMismatch));
    try std.testing.expectEqual(error.Recoverable, DataLink.mapInboundError(error.OutOfMemory));
}

/// A data-link view bound to the currently selected three-bit key.
pub const DataLinkPair = struct {
    link: *DataLink,
    key: u8,

    pub fn send(
        self: DataLinkPair,
        packets: []const []const u8,
        key: ?u8,
        timeout_ms: ?u64,
    ) anyerror!void {
        try self.link.send(packets, key orelse self.key, timeout_ms);
    }

    pub fn receive(
        self: DataLinkPair,
        packets: []const []const u8,
        key: u8,
    ) anyerror!void {
        try self.link.receive(packets, key);
    }
};
