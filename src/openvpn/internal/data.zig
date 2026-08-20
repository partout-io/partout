// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const net_mod = @import("../../net/exports.zig");
const auth_mod = @import("auth.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const crypto_mod = @import("crypto.zig");
const errors_mod = @import("errors.zig");
const helpers_mod = @import("helpers.zig");
const processing_mod = @import("processing.zig");

const api = core_mod.api;
const c = helpers_mod.c;
const c_common = c_exports_mod.common;
const c_crypto = c_exports_mod.crypto;
const log = core_mod.logging;

const CryptoBackend = c_exports_mod.CryptoBackend;
const CryptoKeys = crypto_mod.CryptoKeys;
const CryptoKeysBridge = crypto_mod.CryptoKeysBridge;
const DataConstants = constants_mod.Data;
const LinkProcessor = processing_mod.LinkProcessor;
const PRF = auth_mod.PRF;
const PRNG = crypto_mod.PRNG;
const ZeroingData = crypto_mod.ZeroingData;

/// C-backed OpenVPN data path.
///
/// `mode` ownership transfers to `createWithMode` on success and is ultimately
/// released by `destroy`. Cryptographic/framing transforms, replay-window
/// bookkeeping, and ping recognition delegate to the existing C routines;
/// this type only owns buffers and orchestrates packet batches.
pub const DataPath = struct {
    pub const Parameters = struct {
        backend: CryptoBackend,
        cipher: ?api.OpenVPNCipher,
        digest: ?api.OpenVPNDigest,
        compression_framing: api.OpenVPNCompressionFraming,
        peer_id: ?u32,
    };

    pub const DecryptedPacket = struct {
        packet_id: u32,
        is_keep_alive: bool,
        data: []u8,

        pub fn deinit(self: *DecryptedPacket, allocator: std.mem.Allocator) void {
            allocator.free(self.data);
        }
    };

    pub const DecryptResult = struct {
        packets: [][]u8,
        keep_alive: bool,

        pub fn deinit(self: *DecryptResult, allocator: std.mem.Allocator) void {
            core_mod.util.freeSliceOfStrings(allocator, self.packets);
        }
    };

    pub const Error = std.mem.Allocator.Error || error{
        CompressionMismatch,
        CryptoFailure,
        DataPathFailure,
        Reconnect,
        UnsupportedAlgorithm,
    };

    allocator: std.mem.Allocator,
    mode: *c.openvpn_dp_mode,
    enc_buffer: *c_common.pp_zd,
    dec_buffer: *c_common.pp_zd,
    replay: *c.openvpn_replay,
    out_packet_id: u32 = 0,

    const resize_step: usize = 1024;
    const initial_buffer_size: usize = 64 * 1024;
    const max_packet_id: u32 = std.math.maxInt(u32) - 10 * 1024;

    fn createWithMode(
        allocator: std.mem.Allocator,
        mode: *c.openvpn_dp_mode,
        peer_id: u32,
    ) !*DataPath {
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

    pub fn createWithPRF(
        allocator: std.mem.Allocator,
        parameters: Parameters,
        prf: *const PRF,
        prng: PRNG,
    ) Error!*DataPath {
        var seed = try prng.safeData(DataConstants.prng_seed_length);
        defer seed.deinit();
        return createWithSeed(allocator, parameters, prf, seed);
    }

    fn createWithSeed(
        allocator: std.mem.Allocator,
        parameters: Parameters,
        prf: *const PRF,
        seed: ZeroingData,
    ) Error!*DataPath {
        const functions = (c_exports_mod.cryptoFunctionTable(parameters.backend) catch
            return error.UnsupportedAlgorithm).enc;
        const init_seed = functions.init_seed orelse return error.UnsupportedAlgorithm;
        if (!init_seed(seed.bytes(), seed.length())) return error.CryptoFailure;
        var keys = prf.derive() catch return error.CryptoFailure;
        defer keys.deinit();
        return createWithKeys(allocator, parameters, functions, &keys);
    }

    fn createWithKeys(
        allocator: std.mem.Allocator,
        parameters: Parameters,
        functions: c_crypto.pp_crypto_enc_fnt,
        keys: *const CryptoKeys,
    ) Error!*DataPath {
        var bridge = CryptoKeysBridge.init(keys);
        defer bridge.deinit();

        const framing = nativeFraming(parameters.compression_framing);
        const cipher_name = if (parameters.cipher) |cipher| cipher.raw() else null;
        const is_aead = if (parameters.cipher) |cipher|
            configuration_mod.cipherEmbedsDigest(cipher)
        else
            false;
        const mode: *c.openvpn_dp_mode = if (is_aead) blk: {
            const name = cipher_name orelse return error.UnsupportedAlgorithm;
            break :blk c.openvpn_dp_mode_ad_create_aead(
                @ptrCast(&functions),
                name.ptr,
                DataConstants.aead_tag_length,
                DataConstants.aead_id_length,
                @ptrCast(bridge.native()),
                framing,
            ) orelse return error.UnsupportedAlgorithm;
        } else blk: {
            const digest = parameters.digest orelse return error.UnsupportedAlgorithm;
            break :blk c.openvpn_dp_mode_hmac_create_cbc(
                @ptrCast(&functions),
                if (cipher_name) |value| value.ptr else null,
                digest.raw().ptr,
                @ptrCast(bridge.native()),
                framing,
            ) orelse return error.UnsupportedAlgorithm;
        };
        errdefer c.openvpn_dp_mode_free(mode);
        return createWithMode(
            allocator,
            mode,
            parameters.peer_id orelse c.OpenVPNPacketPeerIdDisabled,
        );
    }

    pub fn destroy(self: *const DataPath) void {
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
    ) ![][]u8 {
        var result: std.ArrayList([]u8) = .empty;
        errdefer core_mod.util.deinitListOfStrings(allocator, &result);
        try result.ensureTotalCapacity(allocator, packets.len);
        for (packets) |packet| {
            self.out_packet_id = std.math.add(u32, self.out_packet_id, 1) catch {
                log.write(.notice, "OpenVPN data packet counter exhausted; reconnecting");
                return error.Reconnect;
            };
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
    ) !DecryptResult {
        var result: std.ArrayList([]u8) = .empty;
        errdefer core_mod.util.deinitListOfStrings(allocator, &result);
        try result.ensureTotalCapacity(allocator, packets.len);
        var keep_alive = false;
        for (packets) |packet| {
            var tuple = try self.decryptAndParse(allocator, packet);
            if (tuple.packet_id > max_packet_id) {
                tuple.deinit(allocator);
                log.write(.notice, "OpenVPN peer data packet counter exhausted; reconnecting");
                return error.Reconnect;
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
        }
        return .{
            .packets = try result.toOwnedSlice(allocator),
            .keep_alive = keep_alive,
        };
    }

    pub fn assembleAndEncrypt(
        self: *DataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
        key: u8,
        packet_id: u32,
    ) ![]u8 {
        const capacity = c.openvpn_dp_mode_assemble_and_encrypt_capacity(self.mode, packet.len);
        ensureCapacity(self.enc_buffer, capacity);
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

    pub fn decryptAndParse(
        self: *DataPath,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) !DecryptedPacket {
        ensureCapacity(self.dec_buffer, packet.len);
        var packet_id: u32 = 0;
        var ignored_header: u8 = 0;
        var keep_alive = false;
        var native_error = emptyNativeError();
        const data: *c_common.pp_zd = @ptrCast(c.openvpn_dp_mode_decrypt_and_parse(
            self.mode,
            @ptrCast(self.dec_buffer),
            &packet_id,
            &ignored_header,
            &keep_alive,
            packet.ptr,
            packet.len,
            &native_error,
        ) orelse return nativeError(native_error));
        defer c_common.pp_zd_free(data);
        return .{
            .packet_id = packet_id,
            .is_keep_alive = keep_alive,
            .data = try allocator.dupe(u8, data.*.bytes[0..data.*.length]),
        };
    }

    fn ensureCapacity(buffer: *c_common.pp_zd, count: usize) void {
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

    fn nativeError(native: c.openvpn_dp_error) error{
        CompressionMismatch,
        CryptoFailure,
        DataPathFailure,
    } {
        return switch (native.dp_code) {
            c.OpenVPNDataPathErrorNone => error.DataPathFailure,
            c.OpenVPNDataPathErrorCompression => error.CompressionMismatch,
            c.OpenVPNDataPathErrorCrypto => errors_mod.cryptoError(native.crypto_code),
            else => error.DataPathFailure,
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
    data_path: *DataPath,

    /// `data_path` ownership transfers only when this function succeeds.
    pub fn create(
        allocator: std.mem.Allocator,
        key: u8,
        data_path: *DataPath,
    ) !*DataChannel {
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
        self.data_path.destroy();
        allocator.destroy(self);
    }

    /// The caller owns the returned packet rows and outer slice.
    pub fn encrypt(
        self: *const DataChannel,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) ![][]u8 {
        return self.data_path.encryptPackets(allocator, packets, self.key);
    }

    /// The caller owns the returned packet rows and outer slice.
    pub fn decrypt(
        self: *const DataChannel,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) ![][]u8 {
        const result = try self.data_path.decryptPackets(allocator, packets);
        if (result.keep_alive)
            log.write(.debug, "Data: Received ping, do nothing");
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
    looper: *net_mod.Looper,
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
        looper: *net_mod.Looper,
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
        self: *const DataLink,
        packets: []const []const u8,
        key: u8,
    ) !void {
        const channel = self.callbacks.data_channel(self.context, key) orelse return;
        const decrypted = channel.decrypt(self.allocator, packets) catch |err| {
            log.write(.err, "Unable to decrypt packets, is DataChannel properly configured?");
            return err;
        };
        defer core_mod.util.freeSliceOfStrings(self.allocator, decrypted);
        if (decrypted.len == 0) return;

        self.callbacks.report_inbound_data_count(
            self.context,
            flatCount(decrypted),
        );
        try self.looper.writeQueued(asConstPackets(decrypted), .tun);
    }

    pub fn send(
        self: *const DataLink,
        packets: []const []const u8,
        key: u8,
        timeout_ms: ?u64,
    ) !void {
        const channel = self.callbacks.data_channel(self.context, key) orelse return;
        const encrypted = channel.encrypt(self.allocator, packets) catch |err| {
            log.write(.err, "Unable to encrypt packets, is DataChannel properly configured?");
            return err;
        };
        defer core_mod.util.freeSliceOfStrings(self.allocator, encrypted);
        if (encrypted.len == 0) return;

        self.callbacks.report_outbound_data_count(
            self.context,
            flatCount(encrypted),
        );

        var processed = try self.link_processor.processOutbound(asConstPackets(encrypted));
        defer processed.deinit();

        if (timeout_ms) |timeout| {
            if (!self.looper.isOnQueue()) return error.ReentrantCall;

            const start = core_mod.concurrency.monotonicNs();
            const deadline = start +| timeout *| @as(u64, std.time.ns_per_ms);
            while (true) {
                self.looper.write(processed.packets(), .link, true) catch |err| {
                    if (core_mod.concurrency.monotonicNs() < deadline) continue;
                    log.writef(.err, "Data: Failed synchronous LINK write during send data: {s}", .{
                        @errorName(err),
                    });
                    return error.Timeout;
                };
                return;
            }
        } else {
            self.looper.writeQueued(processed.packets(), .link) catch |err| {
                log.writef(.err, "Data: Failed LINK write during send data: {s}", .{
                    @errorName(err),
                });
                return err;
            };
        }
    }

    fn flatCount(packets: []const []u8) usize {
        var result: usize = 0;
        for (packets) |packet| result +|= packet.len;
        return result;
    }

    fn asConstPackets(packets: []const []u8) []const []const u8 {
        // Slice mutability is not part of the packet identity. The returned
        // view borrows the exact same rows and is used only for synchronous
        // processing/copying by PacketProcessor and Looper.
        return @ptrCast(packets);
    }
};

/// A data-link view bound to the currently selected three-bit key.
pub const DataLinkPair = struct {
    link: *DataLink,
    key: u8,

    pub fn send(
        self: DataLinkPair,
        packets: []const []const u8,
        key: ?u8,
        timeout_ms: ?u64,
    ) !void {
        return self.link.send(packets, key orelse self.key, timeout_ms);
    }

    pub fn receive(
        self: DataLinkPair,
        packets: []const []const u8,
        key: u8,
    ) !void {
        return self.link.receive(packets, key);
    }
};

pub const testing = struct {
    pub fn createMockDataPath(
        allocator: std.mem.Allocator,
        peer_id: u32,
    ) !*DataPath {
        return createMockDataPathWithFraming(
            allocator,
            peer_id,
            .disabled,
            false,
        );
    }

    pub fn createMockDataPathWithFraming(
        allocator: std.mem.Allocator,
        peer_id: u32,
        framing: api.OpenVPNCompressionFraming,
        authenticated: bool,
    ) !*DataPath {
        const native_framing = DataPath.nativeFraming(framing);
        const mode = if (authenticated)
            c.openvpn_dp_mode_hmac_create_mock(native_framing)
        else
            c.openvpn_dp_mode_ad_create_mock(native_framing);
        return DataPath.createWithMode(allocator, mode, peer_id);
    }
};
