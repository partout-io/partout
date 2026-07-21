// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const c = @import("c.zig").api;
const CDataPath = @import("c_data_path.zig").CDataPath;
const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
const CryptoKeysBridge = @import("crypto_keys_bridge.zig").CryptoKeysBridge;
const CryptoKeysPRF = @import("crypto_keys_prf.zig").CryptoKeysPRF;
const DataChannelConstants = @import("data_channel_constants.zig").DataChannel;
const DataPathParameters = @import("data_path_parameters.zig").DataPathParameters;
const data_path_protocol = @import("data_path_protocol.zig");
const DataPathProtocol = data_path_protocol.DataPathProtocol;
const DataPathDecryptResult = @import("data_path_decrypt_result.zig").DataPathDecryptResult;
const PRNG = @import("prng.zig").PRNG;
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

const api = core.api;

/// Owning facade over a concrete data path.
pub const DataPathWrapper = struct {
    pub const Parameters = DataPathParameters;

    data_path: DataPathProtocol,

    pub fn init(data_path: DataPathProtocol) DataPathWrapper {
        return .{ .data_path = data_path };
    }

    pub fn deinit(self: *DataPathWrapper) void {
        self.data_path.deinit();
        self.* = undefined;
    }

    pub fn takeProtocol(self: *DataPathWrapper) DataPathProtocol {
        const data_path = self.data_path;
        self.* = undefined;
        return data_path;
    }

    pub fn encrypt(
        self: DataPathWrapper,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
        key: u8,
    ) anyerror![][]u8 {
        return self.data_path.encrypt(allocator, packets, key);
    }

    pub fn decrypt(
        self: DataPathWrapper,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror!DataPathDecryptResult {
        return self.data_path.decrypt(allocator, packets);
    }

    pub fn nativeWithPRF(
        allocator: std.mem.Allocator,
        parameters: DataPathParameters,
        prf: *const CryptoKeysPRF,
        prng: PRNG,
    ) anyerror!DataPathWrapper {
        var seed = try prng.safeData(allocator, DataChannelConstants.prng_seed_length);
        defer seed.deinit(allocator);
        return nativeWithSeed(allocator, parameters, prf, seed);
    }

    pub fn nativeWithSeed(
        allocator: std.mem.Allocator,
        parameters: DataPathParameters,
        prf: *const CryptoKeysPRF,
        seed: ZeroingData,
    ) anyerror!DataPathWrapper {
        const init_seed = parameters.fnt.init_seed orelse return error.CryptoCreation;
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
            const name = cipher_name orelse return error.DataPathAlgorithm;
            break :blk c.openvpn_dp_mode_ad_create_aead(
                @ptrCast(&parameters.fnt),
                name.ptr,
                DataChannelConstants.aead_tag_length,
                DataChannelConstants.aead_id_length,
                @ptrCast(bridge.native()),
                framing,
            ) orelse return error.DataPathCreation;
        } else blk: {
            const digest = digest_name orelse return error.DataPathAlgorithm;
            break :blk c.openvpn_dp_mode_hmac_create_cbc(
                @ptrCast(&parameters.fnt),
                if (cipher_name) |value| value.ptr else null,
                digest.ptr,
                @ptrCast(bridge.native()),
                framing,
            ) orelse return if (cipher_name != null)
                error.DataPathAlgorithm
            else
                error.DataPathCreation;
        };
        errdefer c.openvpn_dp_mode_free(mode);

        const implementation = try CDataPath.create(
            allocator,
            mode,
            parameters.peer_id orelse c.OpenVPNPacketPeerIdDisabled,
        );
        return init(implementation.asProtocol());
    }

    pub fn nativeADMock(
        allocator: std.mem.Allocator,
        framing: api.OpenVPNCompressionFraming,
    ) std.mem.Allocator.Error!DataPathWrapper {
        const mode = c.openvpn_dp_mode_ad_create_mock(nativeFraming(framing));
        errdefer c.openvpn_dp_mode_free(mode);
        const implementation = try CDataPath.create(
            allocator,
            mode,
            c.OpenVPNPacketPeerIdDisabled,
        );
        return init(implementation.asProtocol());
    }

    pub fn nativeHMACMock(
        allocator: std.mem.Allocator,
        framing: api.OpenVPNCompressionFraming,
    ) std.mem.Allocator.Error!DataPathWrapper {
        const mode = c.openvpn_dp_mode_hmac_create_mock(nativeFraming(framing));
        errdefer c.openvpn_dp_mode_free(mode);
        const implementation = try CDataPath.create(
            allocator,
            mode,
            c.OpenVPNPacketPeerIdDisabled,
        );
        return init(implementation.asProtocol());
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
