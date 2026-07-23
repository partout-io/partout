// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const c_common = source.c_common;
const c_crypto = source.c_crypto;
const TLSWrapper = source.openvpn_internal.tls.TLSWrapper;

test "TLSWrapper delegates its complete TLS surface to the C table" {
    const Fake = struct {
        fn options(tls: c_crypto.pp_tls) [*c]c_crypto.pp_tls_options {
            return @ptrCast(@alignCast(tls.?));
        }

        fn create(
            opt: [*c]const c_crypto.pp_tls_options,
            code: [*c]c_crypto.pp_tls_error_code,
        ) callconv(.c) c_crypto.pp_tls {
            code[0] = c_crypto.PPTLSErrorNone;
            return @ptrCast(@alignCast(@constCast(opt)));
        }

        fn free(tls: c_crypto.pp_tls) callconv(.c) void {
            c_crypto.pp_tls_options_free(options(tls));
        }

        fn start(tls: c_crypto.pp_tls) callconv(.c) bool {
            const opt = options(tls);
            opt.*.on_verify_failure.?(opt.*.ctx);
            return true;
        }

        fn isConnected(_: c_crypto.pp_tls) callconv(.c) bool {
            return true;
        }

        fn pullPlain(_: c_crypto.pp_tls, code: [*c]c_crypto.pp_tls_error_code) callconv(.c) [*c]c_crypto.pp_zd {
            code[0] = c_crypto.PPTLSErrorNone;
            return c_crypto.pp_zd_create_from_data("plain".ptr, "plain".len);
        }

        fn pullCipher(_: c_crypto.pp_tls, code: [*c]c_crypto.pp_tls_error_code) callconv(.c) [*c]c_crypto.pp_zd {
            code[0] = c_crypto.PPTLSErrorNone;
            return c_crypto.pp_zd_create_from_data("cipher".ptr, "cipher".len);
        }

        fn put(
            _: c_crypto.pp_tls,
            _: [*c]const u8,
            _: usize,
            code: [*c]c_crypto.pp_tls_error_code,
        ) callconv(.c) bool {
            code[0] = c_crypto.PPTLSErrorNone;
            return true;
        }

        fn caMD5(_: c_crypto.pp_tls) callconv(.c) [*c]u8 {
            return c_common.pp_dup("0123456789abcdef");
        }

        fn verificationFailed(context: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const caches_directory = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(caches_directory);

    var verification_failures: usize = 0;
    const configuration = api.OpenVPNConfiguration{
        .ca = .{ .pem = "-----BEGIN CERTIFICATE-----\nmock\n-----END CERTIFICATE-----\n" },
    };
    var functions = c_crypto.pp_crypto_fnt_mock().tls;
    functions.create = Fake.create;
    functions.free = Fake.free;
    functions.start = Fake.start;
    functions.is_connected = Fake.isConnected;
    functions.pull_plain = Fake.pullPlain;
    functions.pull_cipher = Fake.pullCipher;
    functions.put_plain = Fake.put;
    functions.put_cipher = Fake.put;
    functions.ca_md5 = Fake.caMD5;
    const tls = try TLSWrapper.create(allocator, .{
        .fnt = functions,
        .caches_directory = caches_directory,
        .configuration = &configuration,
        .verification = .{
            .context = &verification_failures,
            .callback = Fake.verificationFailed,
        },
    });
    defer tls.destroy();

    try tls.start();
    try std.testing.expect(tls.isConnected());
    try std.testing.expectEqual(@as(usize, 1), verification_failures);
    try tls.putPlainText("text");
    try tls.putRawPlainText("raw");
    try tls.putCipherText("encrypted");
    const plain = try tls.pullPlainText(allocator);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("plain", plain);
    const cipher = try tls.pullCipherText(allocator);
    defer allocator.free(cipher);
    try std.testing.expectEqualStrings("cipher", cipher);
    const md5 = try tls.caMD5(allocator);
    defer allocator.free(md5);
    try std.testing.expectEqualStrings("0123456789abcdef", md5);
}
