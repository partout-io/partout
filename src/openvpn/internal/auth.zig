// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const version = @import("../../version.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const crypto_mod = @import("crypto.zig");
const push_mod = @import("push.zig");
const tls_mod = @import("tls.zig");

const api = core_mod.api;
const c_crypto = c_exports_mod.crypto;
const log = core_mod.logging;

const ControlConstants = constants_mod.Control;
const CryptoBackend = c_exports_mod.CryptoBackend;
const CryptoKeys = crypto_mod.CryptoKeys;
const CryptoKeyPair = CryptoKeys.KeyPair;
const KeysConstants = constants_mod.Keys;
const PRNG = crypto_mod.PRNG;
const TLSWrapper = tls_mod.TLSWrapper;
const ZeroingData = crypto_mod.ZeroingData;

/// Key-method 2 client/server random material.
pub const Handshake = struct {
    pre_master: ZeroingData,
    random1: ZeroingData,
    random2: ZeroingData,
    server_random1: ZeroingData,
    server_random2: ZeroingData,

    pub fn clone(self: Handshake) Handshake {
        return .{
            .pre_master = self.pre_master.clone(),
            .random1 = self.random1.clone(),
            .random2 = self.random2.clone(),
            .server_random1 = self.server_random1.clone(),
            .server_random2 = self.server_random2.clone(),
        };
    }

    pub fn deinit(self: *Handshake) void {
        self.pre_master.deinit();
        self.random1.deinit();
        self.random2.deinit();
        self.server_random1.deinit();
        self.server_random2.deinit();
    }
};

/// Parameters for deriving the four OpenVPN key-method 2 keys.
pub const PRF = struct {
    functions: c_crypto.pp_crypto_fnt,
    handshake: Handshake,
    session_id: []u8,
    remote_session_id: []u8,

    /// Clones all input data so this value may outlive the negotiation that
    /// produced it.
    pub fn init(
        allocator: std.mem.Allocator,
        backend: CryptoBackend,
        handshake: *const Handshake,
        session_id: []const u8,
        remote_session_id: []const u8,
    ) !PRF {
        const functions = try c_exports_mod.cryptoFunctionTable(backend);
        return initWithFunctions(
            allocator,
            functions,
            handshake,
            session_id,
            remote_session_id,
        );
    }

    fn initWithFunctions(
        allocator: std.mem.Allocator,
        functions: c_crypto.pp_crypto_fnt,
        handshake: *const Handshake,
        session_id: []const u8,
        remote_session_id: []const u8,
    ) !PRF {
        var owned_handshake = handshake.clone();
        errdefer owned_handshake.deinit();
        const owned_session_id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session_id);
        const owned_remote_session_id = try allocator.dupe(u8, remote_session_id);
        return .{
            .functions = functions,
            .handshake = owned_handshake,
            .session_id = owned_session_id,
            .remote_session_id = owned_remote_session_id,
        };
    }

    pub fn deinit(self: *PRF, allocator: std.mem.Allocator) void {
        self.handshake.deinit();
        allocator.free(self.session_id);
        allocator.free(self.remote_session_id);
    }

    pub fn derive(self: *const PRF) !CryptoKeys {
        var master_data = try prfData(.{
            .functions = self.functions,
            .label = KeysConstants.label1,
            .secret = self.handshake.pre_master.asSlice(),
            .client_seed = self.handshake.random1.asSlice(),
            .server_seed = self.handshake.server_random1.asSlice(),
            .size = KeysConstants.pre_master_length,
        });
        defer master_data.deinit();

        var keys_data = try prfData(.{
            .functions = self.functions,
            .label = KeysConstants.label2,
            .secret = master_data.asSlice(),
            .client_seed = self.handshake.random2.asSlice(),
            .server_seed = self.handshake.server_random2.asSlice(),
            .client_session_id = self.session_id,
            .server_session_id = self.remote_session_id,
            .size = KeysConstants.keys_count * KeysConstants.key_length,
        });
        defer keys_data.deinit();
        if (keys_data.length() != KeysConstants.keys_count * KeysConstants.key_length)
            @panic("OpenVPN PRF returned an unexpected key-data length");

        var parts: [KeysConstants.keys_count]ZeroingData = undefined;
        var initialized: usize = 0;
        errdefer for (parts[0..initialized]) |*part| part.deinit();
        for (&parts, 0..) |*part, index| {
            part.* = try keys_data.sliceCopy(
                index * KeysConstants.key_length,
                KeysConstants.key_length,
            );
            initialized += 1;
        }

        return CryptoKeys.init(
            CryptoKeyPair.init(parts[0].move(), parts[2].move()),
            CryptoKeyPair.init(parts[1].move(), parts[3].move()),
        );
    }

    fn prfData(input: PRFInput) !ZeroingData {
        var seed = ZeroingData.initCopy(input.label);
        defer seed.deinit();
        seed.append(input.client_seed);
        seed.append(input.server_seed);
        if (input.client_session_id) |value| seed.append(value);
        if (input.server_session_id) |value| seed.append(value);

        const half = input.secret.len / 2;
        const half_rounded_up = half + (input.secret.len & 1);
        var hash1 = try keysHash(
            input.functions,
            "MD5",
            input.secret[0..half_rounded_up],
            seed.asSlice(),
            input.size,
        );
        defer hash1.deinit();
        var hash2 = try keysHash(
            input.functions,
            "SHA1",
            input.secret[half..][0..half_rounded_up],
            seed.asSlice(),
            input.size,
        );
        defer hash2.deinit();

        var result = ZeroingData.init(input.size);
        for (result.asMutableSlice(), hash1.asSlice(), hash2.asSlice()) |*dst, lhs, rhs| dst.* = lhs ^ rhs;
        return result;
    }

    fn keysHash(
        functions: c_crypto.pp_crypto_fnt,
        digest_name: [:0]const u8,
        secret: []const u8,
        seed: []const u8,
        size: usize,
    ) !ZeroingData {
        var output = ZeroingData.init(0);
        defer output.deinit();
        var chain = try hmac(functions, digest_name, secret, seed);
        defer chain.deinit();

        while (output.length() < size) {
            var chain_and_seed = chain.clone();
            defer chain_and_seed.deinit();
            chain_and_seed.append(seed);

            var block = try hmac(functions, digest_name, secret, chain_and_seed.asSlice());
            defer block.deinit();
            output.append(block.asSlice());

            var next_chain = try hmac(functions, digest_name, secret, chain.asSlice());
            chain.deinit();
            chain = next_chain.move();
        }

        return output.sliceCopy(0, size);
    }

    fn hmac(
        functions: c_crypto.pp_crypto_fnt,
        digest_name: [:0]const u8,
        secret: []const u8,
        data: []const u8,
    ) !ZeroingData {
        const hmac_max_length = 128;
        var buffer = ZeroingData.init(hmac_max_length);
        defer buffer.deinit();
        var context = c_crypto.pp_hmac_ctx{
            .dst = buffer.mutableBytes(),
            .dst_len = buffer.length(),
            .digest_name = digest_name.ptr,
            .secret = secret.ptr,
            .secret_len = secret.len,
            .data = data.ptr,
            .data_len = data.len,
        };
        const hmac_do = functions.hmac_do orelse return error.UnsupportedAlgorithm;
        const length = hmac_do(&context);
        if (length == 0 or length > buffer.length()) return error.UnsupportedAlgorithm;
        return buffer.sliceCopy(0, length);
    }

    pub const testing = struct {
        pub const initWithFunctions = PRF.initWithFunctions;
    };
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
    ) !Authenticator {
        var pre_master = try prng.safeData(KeysConstants.pre_master_length);
        errdefer pre_master.deinit();
        var random1 = try prng.safeData(KeysConstants.random_length);
        errdefer random1.deinit();
        var random2 = try prng.safeData(KeysConstants.random_length);
        errdefer random2.deinit();
        const control_buffer = ZeroingData.init(0);

        var username_data: ?ZeroingData = null;
        var password_data: ?ZeroingData = null;
        if (username != null and password != null) {
            username_data = ZeroingData.initString(username.?, true);
            password_data = ZeroingData.initString(password.?, true);
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
        self.control_buffer.deinit();
        self.pre_master.deinit();
        self.random1.deinit();
        self.random2.deinit();
        if (self.server_random1) |*value| value.deinit();
        if (self.server_random2) |*value| value.deinit();
        if (self.username) |*value| value.deinit();
        if (self.password) |*value| value.deinit();
    }

    pub fn reset(self: *Authenticator) void {
        self.control_buffer.clear();
        self.pre_master.zero();
        self.random1.zero();
        self.random2.zero();
        if (self.server_random1) |*value| value.deinit();
        if (self.server_random2) |*value| value.deinit();
        if (self.username) |*value| value.deinit();
        if (self.password) |*value| value.deinit();
        self.server_random1 = null;
        self.server_random2 = null;
        self.server_options = null;
        self.username = null;
        self.password = null;
    }

    pub fn putAuth(
        self: *const Authenticator,
        tls: *TLSWrapper,
        configuration: *const api.OpenVPNConfiguration,
    ) !void {
        var raw = try self.authData(configuration);
        defer raw.deinit();
        log.write(.info, "TLS.auth: Put plaintext");
        try tls.putRawPlainText(raw.asSlice());
    }

    fn authData(
        self: *const Authenticator,
        configuration: *const api.OpenVPNConfiguration,
    ) !ZeroingData {
        const allocator = self.allocator;
        var raw = ZeroingData.initCopy(&ControlConstants.tls_prefix);
        errdefer raw.deinit();

        raw.appendData(self.pre_master);
        raw.appendData(self.random1);
        raw.appendData(self.random2);

        const local_options = try configuration_mod.localOptionsStringAlloc(
            allocator,
            configuration,
            self.with_local_options,
        );
        defer allocator.free(local_options);
        log.writef(.info, "TLS.auth: Local options: {s}", .{local_options});
        var local_options_data = ZeroingData.initString(local_options, true);
        defer local_options_data.deinit();
        appendSized(&raw, local_options_data);

        if (self.username != null and self.password != null) {
            appendSized(&raw, self.username.?);
            appendSized(&raw, self.password.?);
        } else {
            raw.append(&.{ 0, 0, 0, 0 });
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
            std.fmt.comptimePrint("{s} {s}", .{ version.identifier, version.number }),
            self.ssl_version,
            extra_lines,
        );
        defer allocator.free(peer_info);
        var peer_info_data = ZeroingData.initString(peer_info, true);
        defer peer_info_data.deinit();
        appendSized(&raw, peer_info_data);
        return raw;
    }

    pub fn appendControlData(
        self: *Authenticator,
        data: []const u8,
    ) void {
        self.control_buffer.append(data);
    }

    pub fn parseAuthReply(self: *Authenticator) !bool {
        const prefix_length = ControlConstants.tls_prefix.len;
        const minimum_length = prefix_length + 2 * KeysConstants.random_length + 2;
        if (self.control_buffer.length() < minimum_length) return false;
        if (!std.mem.eql(
            u8,
            self.control_buffer.asSlice()[0..prefix_length],
            &ControlConstants.tls_prefix,
        )) return error.WrongControlDataPrefix;

        var offset = prefix_length;
        const random1_offset = offset;
        offset += KeysConstants.random_length;
        const random2_offset = offset;
        offset += KeysConstants.random_length;
        const options_length = try self.control_buffer.networkU16(offset);
        offset += 2;
        if (self.control_buffer.length() - offset < options_length) return false;

        var server_random1 = try self.control_buffer.sliceCopy(
            random1_offset,
            KeysConstants.random_length,
        );
        errdefer server_random1.deinit();
        var server_random2 = try self.control_buffer.sliceCopy(
            random2_offset,
            KeysConstants.random_length,
        );
        errdefer server_random2.deinit();
        const options_end = offset + @as(usize, options_length);
        const server_options_data = self.control_buffer.asSlice()[offset..options_end];
        offset = options_end;

        log.write(.info, "TLS.auth: Parsed server random");

        const parsed_options: ?ServerOCC = if (std.mem.indexOfScalar(u8, server_options_data, 0)) |end| blk: {
            const value = server_options_data[0..end];
            log.writef(.info, "TLS.auth: Parsed server options (string): \"{s}\"", .{value});
            const options = ServerOCC.parse(value);
            log.writef(.info, "TLS.auth: Server options: cipher={s}, digest={s}", .{
                if (options.cipher) |cipher| cipher.raw() else "nil",
                if (options.digest) |digest| digest.raw() else "nil",
            });
            break :blk options;
        } else null;
        try self.control_buffer.removePrefix(offset);

        if (self.server_random1) |*value| value.deinit();
        if (self.server_random2) |*value| value.deinit();
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
    ) ![][]u8 {
        var messages: std.ArrayList([]u8) = .empty;
        errdefer core_mod.util.deinitListOfStrings(allocator, &messages);
        var offset: usize = 0;
        while (offset < self.control_buffer.length()) {
            const tail = self.control_buffer.asSlice()[offset..];
            const length = std.mem.indexOfScalar(u8, tail, 0) orelse break;
            const message = tail[0..length];
            if (!std.unicode.utf8ValidateSlice(message)) break;
            try core_mod.util.appendOwned(allocator, &messages, message);
            offset += length + 1;
        }
        try self.control_buffer.removePrefix(offset);
        return messages.toOwnedSlice(allocator);
    }

    /// Returns an owned handshake once both server randoms are available.
    pub fn response(self: *const Authenticator) ?Handshake {
        const remote1 = self.server_random1 orelse return null;
        const remote2 = self.server_random2 orelse return null;
        return .{
            .pre_master = self.pre_master.clone(),
            .random1 = self.random1.clone(),
            .random2 = self.random2.clone(),
            .server_random1 = remote1.clone(),
            .server_random2 = remote2.clone(),
        };
    }

    fn appendSized(
        destination: *ZeroingData,
        source: ZeroingData,
    ) void {
        if (source.length() > std.math.maxInt(u16))
            @panic("OpenVPN auth field exceeds the 65535-byte protocol limit");
        var encoded: [2]u8 = undefined;
        std.mem.writeInt(u16, &encoded, @intCast(source.length()), .big);
        destination.append(&encoded);
        destination.appendData(source);
    }

    fn cipherLineAlloc(
        allocator: std.mem.Allocator,
        ciphers: []const api.OpenVPNCipher,
    ) ![]u8 {
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

pub const testing = struct {
    pub const ServerOptions = ServerOCC;
    pub const authData = Authenticator.authData;
};

const PRFInput = struct {
    functions: c_crypto.pp_crypto_fnt,
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
            const line = core_mod.util.trim(raw_line);
            var components = std.mem.tokenizeAny(u8, line, " \t\r\n");
            const option = components.next() orelse continue;
            const value = components.next() orelse continue;

            if (std.ascii.eqlIgnoreCase(option, "cipher")) {
                result.cipher = core_mod.util.parseRawIgnoreCase(api.OpenVPNCipher, value);
            } else if (std.ascii.eqlIgnoreCase(option, "data-ciphers-fallback")) {
                if (result.cipher == null)
                    result.cipher = core_mod.util.parseRawIgnoreCase(api.OpenVPNCipher, value);
            } else if (std.ascii.eqlIgnoreCase(option, "auth")) {
                result.digest = core_mod.util.parseRawIgnoreCase(api.OpenVPNDigest, value);
            }
        }
        return result;
    }
};
