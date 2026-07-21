// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c = @import("c.zig").api;
const errors = @import("errors.zig");
const Keys = @import("key_constants.zig").Keys;
const CryptoKeyPair = @import("crypto_key_pair.zig").CryptoKeyPair;
const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
const Handshake = @import("handshake.zig").Handshake;
const PRFInput = @import("prf_input.zig").PRFInput;
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

/// Parameters for deriving the four OpenVPN key-method 2 keys.
pub const CryptoKeysPRF = struct {
    fnt: c.pp_crypto_fnt,
    handshake: ?Handshake,
    session_id: ?[]u8,
    remote_session_id: ?[]u8,

    pub const Error = std.mem.Allocator.Error || errors.PPCryptoError;

    /// Clones all input data so this value may outlive the negotiation that
    /// produced it.
    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_fnt,
        handshake: *const Handshake,
        session_id: []const u8,
        remote_session_id: []const u8,
    ) std.mem.Allocator.Error!CryptoKeysPRF {
        var owned_handshake = try handshake.clone(allocator);
        errdefer owned_handshake.deinit(allocator);
        const owned_session_id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session_id);
        const owned_remote_session_id = try allocator.dupe(u8, remote_session_id);
        return .{
            .fnt = fnt,
            .handshake = owned_handshake,
            .session_id = owned_session_id,
            .remote_session_id = owned_remote_session_id,
        };
    }

    pub fn deinit(self: *CryptoKeysPRF, allocator: std.mem.Allocator) void {
        if (self.handshake) |*value| value.deinit(allocator);
        if (self.session_id) |value| allocator.free(value);
        if (self.remote_session_id) |value| allocator.free(value);
        self.handshake = null;
        self.session_id = null;
        self.remote_session_id = null;
    }

    pub fn move(self: *CryptoKeysPRF) CryptoKeysPRF {
        const result = self.*;
        self.handshake = null;
        self.session_id = null;
        self.remote_session_id = null;
        return result;
    }

    pub fn derive(self: *const CryptoKeysPRF, allocator: std.mem.Allocator) Error!CryptoKeys {
        std.debug.assert(self.handshake != null);
        std.debug.assert(self.session_id != null);
        std.debug.assert(self.remote_session_id != null);
        const handshake = self.handshake.?;

        var master_data = try prfData(allocator, .{
            .fnt = self.fnt,
            .label = Keys.label1,
            .secret = handshake.pre_master.bytes,
            .client_seed = handshake.random1.bytes,
            .server_seed = handshake.server_random1.bytes,
            .size = Keys.pre_master_length,
        });
        defer master_data.deinit(allocator);

        var keys_data = try prfData(allocator, .{
            .fnt = self.fnt,
            .label = Keys.label2,
            .secret = master_data.bytes,
            .client_seed = handshake.random2.bytes,
            .server_seed = handshake.server_random2.bytes,
            .client_session_id = self.session_id.?,
            .server_session_id = self.remote_session_id.?,
            .size = Keys.keys_count * Keys.key_length,
        });
        defer keys_data.deinit(allocator);
        std.debug.assert(keys_data.bytes.len == Keys.keys_count * Keys.key_length);

        var parts: [Keys.keys_count]ZeroingData = undefined;
        var initialized: usize = 0;
        errdefer for (parts[0..initialized]) |*part| part.deinit(allocator);
        for (&parts, 0..) |*part, index| {
            part.* = keys_data.sliceCopy(
                allocator,
                index * Keys.key_length,
                Keys.key_length,
            ) catch unreachable;
            initialized += 1;
        }

        return CryptoKeys.init(
            CryptoKeyPair.init(parts[0].move(), parts[2].move()),
            CryptoKeyPair.init(parts[1].move(), parts[3].move()),
        );
    }

    fn prfData(allocator: std.mem.Allocator, input: PRFInput) Error!ZeroingData {
        var seed = try ZeroingData.initCopy(allocator, input.label);
        defer seed.deinit(allocator);
        try seed.append(allocator, input.client_seed);
        try seed.append(allocator, input.server_seed);
        if (input.client_session_id) |value| try seed.append(allocator, value);
        if (input.server_session_id) |value| try seed.append(allocator, value);

        const half = input.secret.len / 2;
        const half_rounded_up = half + (input.secret.len & 1);
        var hash1 = try keysHash(
            allocator,
            input.fnt,
            "MD5",
            input.secret[0..half_rounded_up],
            seed.bytes,
            input.size,
        );
        defer hash1.deinit(allocator);
        var hash2 = try keysHash(
            allocator,
            input.fnt,
            "SHA1",
            input.secret[half..][0..half_rounded_up],
            seed.bytes,
            input.size,
        );
        defer hash2.deinit(allocator);

        const result = try ZeroingData.init(allocator, input.size);
        for (result.bytes, hash1.bytes, hash2.bytes) |*dst, lhs, rhs| dst.* = lhs ^ rhs;
        return result;
    }

    fn keysHash(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_fnt,
        digest_name: [*:0]const u8,
        secret: []const u8,
        seed: []const u8,
        size: usize,
    ) Error!ZeroingData {
        var output = try ZeroingData.init(allocator, 0);
        errdefer output.deinit(allocator);
        var chain = try hmac(allocator, fnt, digest_name, secret, seed);
        defer chain.deinit(allocator);

        while (output.bytes.len < size) {
            var chain_and_seed = try chain.clone(allocator);
            defer chain_and_seed.deinit(allocator);
            try chain_and_seed.append(allocator, seed);

            var block = try hmac(allocator, fnt, digest_name, secret, chain_and_seed.bytes);
            defer block.deinit(allocator);
            try output.append(allocator, block.bytes);

            var next_chain = try hmac(allocator, fnt, digest_name, secret, chain.bytes);
            chain.deinit(allocator);
            chain = next_chain.move();
        }

        const truncated = output.sliceCopy(allocator, 0, size) catch unreachable;
        output.deinit(allocator);
        return truncated;
    }

    fn hmac(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_fnt,
        digest_name: [*:0]const u8,
        secret: []const u8,
        data: []const u8,
    ) Error!ZeroingData {
        const hmac_max_length = 128;
        var buffer = try ZeroingData.init(allocator, hmac_max_length);
        errdefer buffer.deinit(allocator);
        var context = c.pp_hmac_ctx{
            .dst = buffer.bytes.ptr,
            .dst_len = buffer.bytes.len,
            .digest_name = digest_name,
            .secret = secret.ptr,
            .secret_len = secret.len,
            .data = data.ptr,
            .data_len = data.len,
        };
        const hmac_do = fnt.hmac_do orelse return error.CryptoCreation;
        const length = hmac_do(&context);
        if (length == 0 or length > buffer.bytes.len) return error.CryptoHMACCalculation;
        const result = buffer.sliceCopy(allocator, 0, length) catch unreachable;
        buffer.deinit(allocator);
        return result;
    }
};

test "CryptoKeysPRF owns retained inputs and derives four key-method-2 buffers" {
    const Fake = struct {
        fn hmac(context_pointer: [*c]c.pp_hmac_ctx) callconv(.c) usize {
            const context = &context_pointer[0];
            const length: usize = 16;
            const destination = context.*.dst[0..length];
            const secret = context.*.secret[0..context.*.secret_len];
            const data = context.*.data[0..context.*.data_len];
            for (destination, 0..) |*byte, index| {
                byte.* = secret[index % secret.len] ^
                    data[index % data.len] ^
                    @as(u8, @truncate(index));
            }
            return length;
        }
    };

    const allocator = std.testing.allocator;
    var pre_master = try ZeroingData.init(allocator, Keys.pre_master_length);
    @memset(pre_master.bytes, 0x10);
    var random1 = try ZeroingData.init(allocator, Keys.random_length);
    @memset(random1.bytes, 0x21);
    var random2 = try ZeroingData.init(allocator, Keys.random_length);
    @memset(random2.bytes, 0x32);
    var server_random1 = try ZeroingData.init(allocator, Keys.random_length);
    @memset(server_random1.bytes, 0x43);
    var server_random2 = try ZeroingData.init(allocator, Keys.random_length);
    @memset(server_random2.bytes, 0x54);
    var handshake = Handshake{
        .pre_master = pre_master.move(),
        .random1 = random1.move(),
        .random2 = random2.move(),
        .server_random1 = server_random1.move(),
        .server_random2 = server_random2.move(),
    };
    var fnt = c.pp_crypto_fnt_mock();
    fnt.hmac_do = Fake.hmac;
    const session_id = try allocator.dupe(u8, "12345678");
    const remote_session_id = try allocator.dupe(u8, "ABCDEFGH");
    var prf = try CryptoKeysPRF.init(
        allocator,
        fnt,
        &handshake,
        session_id,
        remote_session_id,
    );
    defer prf.deinit(allocator);

    // The PRF must remain usable after negotiation-owned inputs disappear and
    // after ownership moves into a retaining factory.
    handshake.deinit(allocator);
    allocator.free(session_id);
    allocator.free(remote_session_id);
    var retained_prf = prf.move();
    defer retained_prf.deinit(allocator);

    var keys = try retained_prf.derive(allocator);
    defer keys.deinit(allocator);
    try std.testing.expectEqual(Keys.key_length, keys.cipher.?.encryption_key.bytes.len);
    try std.testing.expectEqual(Keys.key_length, keys.cipher.?.decryption_key.bytes.len);
    try std.testing.expectEqual(Keys.key_length, keys.digest.?.encryption_key.bytes.len);
    try std.testing.expectEqual(Keys.key_length, keys.digest.?.decryption_key.bytes.len);
}
