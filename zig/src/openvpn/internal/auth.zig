// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const crypto_mod = @import("crypto.zig");
const errors_mod = @import("errors.zig");
const push_mod = @import("push.zig");

const api = core_mod.api;
const c_crypto = c_exports_mod.crypto;

const ControlConstants = constants_mod.Control;
const CryptoKeyPair = crypto_mod.CryptoKeyPair;
const CryptoKeys = crypto_mod.CryptoKeys;
const Keys = constants_mod.Keys;
const PRNG = crypto_mod.PRNG;
const ZeroingData = crypto_mod.ZeroingData;

/// Key-method 2 client/server random material.
pub const Handshake = struct {
    pre_master: ZeroingData,
    random1: ZeroingData,
    random2: ZeroingData,
    server_random1: ZeroingData,
    server_random2: ZeroingData,

    pub fn clone(self: Handshake, allocator: std.mem.Allocator) std.mem.Allocator.Error!Handshake {
        var pre_master = try self.pre_master.clone(allocator);
        errdefer pre_master.deinit(allocator);
        var random1 = try self.random1.clone(allocator);
        errdefer random1.deinit(allocator);
        var random2 = try self.random2.clone(allocator);
        errdefer random2.deinit(allocator);
        var server_random1 = try self.server_random1.clone(allocator);
        errdefer server_random1.deinit(allocator);
        const server_random2 = try self.server_random2.clone(allocator);
        return .{
            .pre_master = pre_master,
            .random1 = random1,
            .random2 = random2,
            .server_random1 = server_random1,
            .server_random2 = server_random2,
        };
    }

    pub fn deinit(self: *Handshake, allocator: std.mem.Allocator) void {
        self.pre_master.deinit(allocator);
        self.random1.deinit(allocator);
        self.random2.deinit(allocator);
        self.server_random1.deinit(allocator);
        self.server_random2.deinit(allocator);
        self.* = undefined;
    }
};

/// Parameters for deriving the four OpenVPN key-method 2 keys.
pub const PRF = struct {
    fnt: c_crypto.pp_crypto_fnt,
    handshake: ?Handshake,
    session_id: ?[]u8,
    remote_session_id: ?[]u8,

    pub const Error = std.mem.Allocator.Error || errors_mod.PRFError;

    /// Clones all input data so this value may outlive the negotiation that
    /// produced it.
    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_fnt,
        handshake: *const Handshake,
        session_id: []const u8,
        remote_session_id: []const u8,
    ) std.mem.Allocator.Error!PRF {
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

    pub fn deinit(self: *PRF, allocator: std.mem.Allocator) void {
        if (self.handshake) |*value| value.deinit(allocator);
        if (self.session_id) |value| allocator.free(value);
        if (self.remote_session_id) |value| allocator.free(value);
        self.handshake = null;
        self.session_id = null;
        self.remote_session_id = null;
    }

    pub fn derive(self: *const PRF, allocator: std.mem.Allocator) Error!CryptoKeys {
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
        fnt: c_crypto.pp_crypto_fnt,
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
        fnt: c_crypto.pp_crypto_fnt,
        digest_name: [*:0]const u8,
        secret: []const u8,
        data: []const u8,
    ) Error!ZeroingData {
        const hmac_max_length = 128;
        var buffer = try ZeroingData.init(allocator, hmac_max_length);
        errdefer buffer.deinit(allocator);
        var context = c_crypto.pp_hmac_ctx{
            .dst = buffer.bytes.ptr,
            .dst_len = buffer.bytes.len,
            .digest_name = digest_name,
            .secret = secret.ptr,
            .secret_len = secret.len,
            .data = data.ptr,
            .data_len = data.len,
        };
        const hmac_do = fnt.hmac_do orelse return error.UnsupportedAlgorithm;
        const length = hmac_do(&context);
        if (length == 0 or length > buffer.bytes.len) return error.UnsupportedAlgorithm;
        const result = buffer.sliceCopy(allocator, 0, length) catch unreachable;
        buffer.deinit(allocator);
        return result;
    }
};

pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    control_buffer: ZeroingData,
    pre_master: ZeroingData,
    random1: ZeroingData,
    random2: ZeroingData,
    server_random1: ?ZeroingData = null,
    server_random2: ?ZeroingData = null,
    server_options: ?ServerOCC = null,
    username: ?ZeroingData = null,
    password: ?ZeroingData = null,
    with_local_options: bool = true,
    ssl_version: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        prng: PRNG,
        username: ?[]const u8,
        password: ?[]const u8,
    ) anyerror!Authenticator {
        var pre_master = try prng.safeData(allocator, Keys.pre_master_length);
        errdefer pre_master.deinit(allocator);
        var random1 = try prng.safeData(allocator, Keys.random_length);
        errdefer random1.deinit(allocator);
        var random2 = try prng.safeData(allocator, Keys.random_length);
        errdefer random2.deinit(allocator);
        var control_buffer = try ZeroingData.init(allocator, 0);
        errdefer control_buffer.deinit(allocator);

        var username_data: ?ZeroingData = null;
        errdefer if (username_data) |*value| value.deinit(allocator);
        var password_data: ?ZeroingData = null;
        errdefer if (password_data) |*value| value.deinit(allocator);
        if (username != null and password != null) {
            username_data = try ZeroingData.initString(allocator, username.?, true);
            password_data = try ZeroingData.initString(allocator, password.?, true);
        }

        return .{
            .allocator = allocator,
            .control_buffer = control_buffer,
            .pre_master = pre_master,
            .random1 = random1,
            .random2 = random2,
            .username = username_data,
            .password = password_data,
        };
    }

    pub fn deinit(self: *Authenticator) void {
        const allocator = self.allocator;
        self.control_buffer.deinit(allocator);
        self.pre_master.deinit(allocator);
        self.random1.deinit(allocator);
        self.random2.deinit(allocator);
        if (self.server_random1) |*value| value.deinit(allocator);
        if (self.server_random2) |*value| value.deinit(allocator);
        if (self.username) |*value| value.deinit(allocator);
        if (self.password) |*value| value.deinit(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Authenticator) void {
        const allocator = self.allocator;
        self.control_buffer.zero();
        self.pre_master.zero();
        self.random1.zero();
        self.random2.zero();
        if (self.server_random1) |*value| value.deinit(allocator);
        if (self.server_random2) |*value| value.deinit(allocator);
        if (self.username) |*value| value.deinit(allocator);
        if (self.password) |*value| value.deinit(allocator);
        self.server_random1 = null;
        self.server_random2 = null;
        self.server_options = null;
        self.username = null;
        self.password = null;
    }

    pub fn putAuth(
        self: *Authenticator,
        tls: anytype,
        configuration: api.OpenVPNConfiguration,
    ) anyerror!void {
        const allocator = self.allocator;
        var raw = try ZeroingData.initCopy(allocator, &ControlConstants.tls_prefix);
        defer raw.deinit(allocator);

        raw.appendData(self.pre_master);
        raw.appendData(self.random1);
        raw.appendData(self.random2);

        const local_options = try configuration_mod.localOptionsStringAlloc(
            allocator,
            configuration,
            self.with_local_options,
        );
        defer allocator.free(local_options);
        var local_options_data = try ZeroingData.initString(allocator, local_options, true);
        defer local_options_data.deinit(allocator);
        try appendSized(&raw, allocator, local_options_data);

        if (self.username != null and self.password != null) {
            try appendSized(&raw, allocator, self.username.?);
            try appendSized(&raw, allocator, self.password.?);
        } else {
            try raw.append(allocator, &.{ 0, 0, 0, 0 });
        }

        const negotiated = try configuration_mod.negotiableDataCiphers(
            allocator,
            configuration,
        );
        defer if (negotiated) |value| allocator.free(value);
        const cipher_line = if (negotiated) |ciphers|
            try cipherLineAlloc(allocator, ciphers)
        else
            null;
        defer if (cipher_line) |value| allocator.free(value);
        const extra_lines: []const []const u8 = if (cipher_line) |value|
            &.{value}
        else
            &.{};
        const peer_info = try push_mod.peerInfoAlloc(
            allocator,
            "io.partout 0.151.0",
            self.ssl_version,
            extra_lines,
        );
        defer allocator.free(peer_info);
        var peer_info_data = try ZeroingData.initString(allocator, peer_info, true);
        defer peer_info_data.deinit(allocator);
        try appendSized(&raw, allocator, peer_info_data);

        try tls.putRawPlainText(raw.bytes);
    }

    pub fn appendControlData(self: *Authenticator, data: []const u8) anyerror!void {
        return self.control_buffer.append(self.allocator, data);
    }

    pub fn parseAuthReply(self: *Authenticator) anyerror!bool {
        const prefix_length = ControlConstants.tls_prefix.len;
        const minimum_length = prefix_length + 2 * Keys.random_length + 2;
        if (self.control_buffer.bytes.len < minimum_length) return false;
        if (!std.mem.eql(
            u8,
            self.control_buffer.bytes[0..prefix_length],
            &ControlConstants.tls_prefix,
        )) return error.WrongControlDataPrefix;

        var offset = prefix_length;
        const random1_offset = offset;
        offset += Keys.random_length;
        const random2_offset = offset;
        offset += Keys.random_length;
        const options_length = self.control_buffer.networkU16(offset) catch unreachable;
        offset += 2;
        if (self.control_buffer.bytes.len - offset < options_length) return false;

        var server_random1 = self.control_buffer.sliceCopy(
            self.allocator,
            random1_offset,
            Keys.random_length,
        ) catch unreachable;
        errdefer server_random1.deinit(self.allocator);
        var server_random2 = self.control_buffer.sliceCopy(
            self.allocator,
            random2_offset,
            Keys.random_length,
        ) catch unreachable;
        errdefer server_random2.deinit(self.allocator);
        var server_options_data = self.control_buffer.sliceCopy(
            self.allocator,
            offset,
            options_length,
        ) catch unreachable;
        defer server_options_data.deinit(self.allocator);
        offset += options_length;

        const parsed_options: ?ServerOCC = if (server_options_data.nullTerminatedString(0)) |value|
            ServerOCC.parse(value)
        else
            null;
        try self.control_buffer.removePrefix(self.allocator, offset);

        if (self.server_random1) |*value| value.deinit(self.allocator);
        if (self.server_random2) |*value| value.deinit(self.allocator);
        self.server_random1 = server_random1.move();
        self.server_random2 = server_random2.move();
        if (parsed_options) |value| self.server_options = value;
        return true;
    }

    /// Returns all complete NUL-terminated messages. Caller owns the rows and
    /// outer slice.
    pub fn parseMessages(
        self: *Authenticator,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![][]u8 {
        var messages: std.ArrayList([]u8) = .empty;
        errdefer {
            for (messages.items) |message| allocator.free(message);
            messages.deinit(allocator);
        }
        var offset: usize = 0;
        while (offset < self.control_buffer.bytes.len) {
            const tail = self.control_buffer.bytes[offset..];
            const length = std.mem.indexOfScalar(u8, tail, 0) orelse break;
            const message = tail[0..length];
            if (!std.unicode.utf8ValidateSlice(message)) break;
            try messages.append(allocator, try allocator.dupe(u8, message));
            offset += length + 1;
        }
        self.control_buffer.removePrefix(self.allocator, offset) catch unreachable;
        return messages.toOwnedSlice(allocator);
    }

    /// Returns an owned handshake once both server randoms are available.
    pub fn response(
        self: *const Authenticator,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!?Handshake {
        const remote1 = self.server_random1 orelse return null;
        const remote2 = self.server_random2 orelse return null;
        var pre_master = try self.pre_master.clone(allocator);
        errdefer pre_master.deinit(allocator);
        var random1 = try self.random1.clone(allocator);
        errdefer random1.deinit(allocator);
        var random2 = try self.random2.clone(allocator);
        errdefer random2.deinit(allocator);
        var server_random1 = try remote1.clone(allocator);
        errdefer server_random1.deinit(allocator);
        const server_random2 = try remote2.clone(allocator);
        return .{
            .pre_master = pre_master,
            .random1 = random1,
            .random2 = random2,
            .server_random1 = server_random1,
            .server_random2 = server_random2,
        };
    }

    fn appendSized(
        destination: *ZeroingData,
        allocator: std.mem.Allocator,
        source: ZeroingData,
    ) anyerror!void {
        if (source.bytes.len > std.math.maxInt(u16)) return error.Assertion;
        var encoded: [2]u8 = undefined;
        std.mem.writeInt(u16, &encoded, @intCast(source.bytes.len), .big);
        try destination.append(allocator, &encoded);
        destination.appendData(source);
    }

    fn cipherLineAlloc(
        allocator: std.mem.Allocator,
        ciphers: []const api.OpenVPNCipher,
    ) std.mem.Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        writer.writeAll("IV_CIPHERS=") catch return error.OutOfMemory;
        for (ciphers, 0..) |cipher, index| {
            if (index > 0) writer.writeByte(':') catch return error.OutOfMemory;
            writer.writeAll(cipher.raw()) catch return error.OutOfMemory;
        }
        return output.toOwnedSlice();
    }
};

const PRFInput = struct {
    fnt: c_crypto.pp_crypto_fnt,
    label: []const u8,
    secret: []const u8,
    client_seed: []const u8,
    server_seed: []const u8,
    client_session_id: ?[]const u8 = null,
    server_session_id: ?[]const u8 = null,
    size: usize,
};

const ServerOCC = struct {
    cipher: ?api.OpenVPNCipher = null,
    digest: ?api.OpenVPNDigest = null,

    pub fn parse(string: []const u8) ServerOCC {
        var result: ServerOCC = .{};
        var lines = std.mem.splitScalar(u8, string, ',');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            var components = std.mem.tokenizeAny(u8, line, " \t\r\n");
            const option = components.next() orelse continue;
            const value = components.next() orelse continue;

            if (std.ascii.eqlIgnoreCase(option, "cipher")) {
                result.cipher = parseCipher(value);
            } else if (std.ascii.eqlIgnoreCase(option, "data-ciphers-fallback")) {
                if (result.cipher == null) result.cipher = parseCipher(value);
            } else if (std.ascii.eqlIgnoreCase(option, "auth")) {
                result.digest = parseDigest(value);
            }
        }
        return result;
    }

    fn parseCipher(value: []const u8) ?api.OpenVPNCipher {
        inline for (std.meta.tags(api.OpenVPNCipher)) |candidate| {
            if (std.ascii.eqlIgnoreCase(value, candidate.raw())) return candidate;
        }
        return null;
    }

    fn parseDigest(value: []const u8) ?api.OpenVPNDigest {
        inline for (std.meta.tags(api.OpenVPNDigest)) |candidate| {
            if (std.ascii.eqlIgnoreCase(value, candidate.raw())) return candidate;
        }
        return null;
    }
};

test "PRF owns retained inputs and derives four key-method-2 buffers" {
    const Fake = struct {
        fn hmac(context_pointer: [*c]c_crypto.pp_hmac_ctx) callconv(.c) usize {
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
    var fnt = c_crypto.pp_crypto_fnt_mock();
    fnt.hmac_do = Fake.hmac;
    const session_id = try allocator.dupe(u8, "12345678");
    const remote_session_id = try allocator.dupe(u8, "ABCDEFGH");
    var prf = try PRF.init(
        allocator,
        fnt,
        &handshake,
        session_id,
        remote_session_id,
    );
    defer prf.deinit(allocator);

    // The PRF must remain usable after negotiation-owned inputs disappear.
    handshake.deinit(allocator);
    allocator.free(session_id);
    allocator.free(remote_session_id);

    var keys = try prf.derive(allocator);
    defer keys.deinit(allocator);
    try std.testing.expectEqual(Keys.key_length, keys.cipher.?.encryption_key.bytes.len);
    try std.testing.expectEqual(Keys.key_length, keys.cipher.?.decryption_key.bytes.len);
    try std.testing.expectEqual(Keys.key_length, keys.digest.?.encryption_key.bytes.len);
    try std.testing.expectEqual(Keys.key_length, keys.digest.?.decryption_key.bytes.len);
}

test "Authenticator frames auth and buffers replies and messages" {
    const allocator = std.testing.allocator;
    const FixedPRNG = struct {
        fn fill(_: ?*anyopaque, destination: []u8) bool {
            @memset(destination, 0x5a);
            return true;
        }
    };
    const TLSRecorder = struct {
        allocator: std.mem.Allocator,
        plaintext: ?[]u8 = null,

        const Self = @This();

        fn putRawPlainText(self: *Self, data: []const u8) anyerror!void {
            if (self.plaintext) |value| self.allocator.free(value);
            self.plaintext = try self.allocator.dupe(u8, data);
        }
    };

    var authenticator = try Authenticator.init(
        allocator,
        .{ .fill_fn = FixedPRNG.fill },
        "user",
        "password",
    );
    defer authenticator.deinit();
    var recorder = TLSRecorder{ .allocator = allocator };
    defer if (recorder.plaintext) |value| allocator.free(value);
    const ciphers = [_]api.OpenVPNCipher{.aes256gcm};
    try authenticator.putAuth(&recorder, .{
        .cipher = .aes256gcm,
        .data_ciphers = &ciphers,
        .digest = .sha256,
    });
    const framed = recorder.plaintext.?;
    try std.testing.expectEqualSlices(
        u8,
        &ControlConstants.tls_prefix,
        framed[0..ControlConstants.tls_prefix.len],
    );
    try std.testing.expect(framed.len >
        ControlConstants.tls_prefix.len + Keys.pre_master_length + 2 * Keys.random_length);
    try std.testing.expect(std.mem.indexOf(u8, framed, "IV_PLAT_VER=") != null);

    const server_options = "V4,cipher AES-256-GCM,auth SHA256\x00";
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.appendSlice(allocator, &ControlConstants.tls_prefix);
    try reply.appendNTimes(allocator, 0x11, Keys.random_length);
    try reply.appendNTimes(allocator, 0x22, Keys.random_length);
    var options_length: [2]u8 = undefined;
    std.mem.writeInt(u16, &options_length, server_options.len, .big);
    try reply.appendSlice(allocator, &options_length);
    try reply.appendSlice(allocator, server_options);

    try authenticator.appendControlData(reply.items[0 .. reply.items.len - 2]);
    try std.testing.expect(!try authenticator.parseAuthReply());
    try authenticator.appendControlData(reply.items[reply.items.len - 2 ..]);
    try std.testing.expect(try authenticator.parseAuthReply());
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, authenticator.server_options.?.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, authenticator.server_options.?.digest.?);
    var handshake = (try authenticator.response(allocator)).?;
    defer handshake.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x11), handshake.server_random1.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x22), handshake.server_random2.bytes[0]);

    try authenticator.appendControlData("AUTH_FAILED\x00PUSH_REPLY,route\x00partial");
    const messages = try authenticator.parseMessages(allocator);
    defer {
        for (messages) |message| allocator.free(message);
        allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("AUTH_FAILED", messages[0]);
    try std.testing.expectEqualStrings("PUSH_REPLY,route", messages[1]);
    try std.testing.expectEqualStrings("partial", authenticator.control_buffer.bytes);
}

test "server OCC extracts only runtime-relevant values" {
    const occ = ServerOCC.parse("V4,dev-type tun,cipher aes-256-cbc,auth sha256,key-method 2");
    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, occ.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, occ.digest.?);
}

test "explicit cipher wins over fallback alias" {
    const occ = ServerOCC.parse("cipher AES-256-GCM,data-ciphers-fallback AES-128-CBC");
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, occ.cipher.?);
}
