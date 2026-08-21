// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const api = core.api;
const c_crypto = source.c_crypto;
const auth = source.openvpn_internal.auth;
const constants = source.openvpn_internal.constants;
const crypto = source.openvpn_internal.crypto;

const Authenticator = auth.Authenticator;
const Handshake = auth.Handshake;
const PRF = auth.PRF;
const ServerOptions = auth.testing.ServerOptions;
const ControlConstants = constants.Control;
const Keys = constants.Keys;
const ZeroingData = crypto.ZeroingData;

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
    var pre_master = ZeroingData.init(Keys.pre_master_length);
    @memset(pre_master.asMutableSlice(), 0x10);
    var random1 = ZeroingData.init(Keys.random_length);
    @memset(random1.asMutableSlice(), 0x21);
    var random2 = ZeroingData.init(Keys.random_length);
    @memset(random2.asMutableSlice(), 0x32);
    var server_random1 = ZeroingData.init(Keys.random_length);
    @memset(server_random1.asMutableSlice(), 0x43);
    var server_random2 = ZeroingData.init(Keys.random_length);
    @memset(server_random2.asMutableSlice(), 0x54);
    var handshake = Handshake{
        .pre_master = pre_master,
        .random1 = random1,
        .random2 = random2,
        .server_random1 = server_random1,
        .server_random2 = server_random2,
    };
    var functions = c_crypto.pp_crypto_fnt_mock();
    functions.hmac_do = Fake.hmac;
    const session_id = try allocator.dupe(u8, "12345678");
    const remote_session_id = try allocator.dupe(u8, "ABCDEFGH");
    var prf = try PRF.testing.initWithFunctions(
        allocator,
        functions,
        &handshake,
        session_id,
        remote_session_id,
    );
    defer prf.deinit(allocator);

    handshake.deinit();
    allocator.free(session_id);
    allocator.free(remote_session_id);

    var keys = try prf.derive();
    defer keys.deinit();
    try std.testing.expectEqual(Keys.key_length, keys.cipher.?.encryption_key.length());
    try std.testing.expectEqual(Keys.key_length, keys.cipher.?.decryption_key.length());
    try std.testing.expectEqual(Keys.key_length, keys.digest.?.encryption_key.length());
    try std.testing.expectEqual(Keys.key_length, keys.digest.?.decryption_key.length());
}

test "Authenticator frames auth and buffers replies and messages" {
    const allocator = std.testing.allocator;
    var authenticator = try Authenticator.init(allocator, .system(), "user", "password");
    defer authenticator.deinit();
    const ciphers = [_]api.OpenVPNCipher{.aes256gcm};
    var auth_data = try auth.testing.authData(&authenticator, &.{
        .cipher = .aes256gcm,
        .data_ciphers = &ciphers,
        .digest = .sha256,
    });
    defer auth_data.deinit();
    const framed = auth_data.asSlice();
    try std.testing.expectEqualSlices(u8, &ControlConstants.tls_prefix, framed[0..ControlConstants.tls_prefix.len]);
    try std.testing.expect(framed.len > ControlConstants.tls_prefix.len + Keys.pre_master_length + 2 * Keys.random_length);
    try std.testing.expect(std.mem.indexOf(u8, framed, "user\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "password\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "IV_MTU=1600\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, framed, "IV_CIPHERS=AES-256-GCM\n") != null);
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

    authenticator.appendControlData(reply.items[0 .. reply.items.len - 2]);
    try std.testing.expect(!try authenticator.parseAuthReply());
    authenticator.appendControlData(reply.items[reply.items.len - 2 ..]);
    try std.testing.expect(try authenticator.parseAuthReply());
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, authenticator.server_options.?.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, authenticator.server_options.?.digest.?);
    var handshake = authenticator.response().?;
    defer handshake.deinit();
    try std.testing.expectEqual(@as(u8, 0x11), handshake.server_random1.asSlice()[0]);
    try std.testing.expectEqual(@as(u8, 0x22), handshake.server_random2.asSlice()[0]);

    authenticator.appendControlData("AUTH_FAILED\x00PUSH_REPLY,route\x00partial");
    const messages = try authenticator.parseMessages(allocator);
    defer core.util.freeSliceOfStrings(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("AUTH_FAILED", messages[0]);
    try std.testing.expectEqualStrings("PUSH_REPLY,route", messages[1]);
    try std.testing.expectEqualStrings("partial", authenticator.control_buffer.asSlice());

    authenticator.reset();
    try std.testing.expectEqual(@as(usize, 0), authenticator.control_buffer.length());
}

test "server OCC extracts only runtime-relevant values" {
    const options = ServerOptions.parse("V4,dev-type tun,cipher aes-256-cbc,auth sha256,key-method 2");
    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, options.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, options.digest.?);
}

test "explicit cipher wins over fallback alias" {
    const options = ServerOptions.parse("cipher AES-256-GCM,data-ciphers-fallback AES-128-CBC");
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, options.cipher.?);
}

test "server OCC accepts the data ciphers fallback alias" {
    const options = ServerOptions.parse("V4,data-ciphers-fallback AES-128-CBC,auth SHA1");
    try std.testing.expectEqual(api.OpenVPNCipher.aes128cbc, options.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha1, options.digest.?);
}
