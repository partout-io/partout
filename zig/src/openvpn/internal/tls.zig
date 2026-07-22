// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const c_exports = @import("../../c/exports.zig");
const c_common = c_exports.common;
const c_crypto = c_exports.crypto;
const TLSConstants = @import("constants.zig").TLS;
const errors = @import("errors.zig");

const api = core.api;

/// Borrowed arguments used to create a TLS engine.
pub const TLSParameters = struct {
    fnt: c_crypto.pp_crypto_tls_fnt,
    caches_directory: []const u8,
    configuration: *const api.OpenVPNConfiguration,
    verification: Verification = .{},

    pub const Verification = struct {
        context: ?*anyopaque = null,
        callback: *const fn (?*anyopaque) void = ignore,

        fn ignore(_: ?*anyopaque) void {}

        pub fn failed(self: Verification) void {
            self.callback(self.context);
        }
    };
};

/// C-backed TLS implementation.
///
/// The C TLS object takes ownership of `pp_tls_options` after a successful
/// `create`. The Zig wrapper owns its verification context, CA file path, and
/// the TLS object itself.
pub const TLSWrapper = struct {
    allocator: std.mem.Allocator,
    fnt: c_crypto.pp_crypto_tls_fnt,
    tls: c_crypto.pp_tls,
    ca_path: [:0]u8,
    verification_context: *VerificationContext,

    const VerificationContext = struct {
        verification: TLSParameters.Verification,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        parameters: TLSParameters,
    ) anyerror!*TLSWrapper {
        const configuration = parameters.configuration.*;
        const ca = configuration.ca orelse return error.TLSFailure;
        const create_tls = parameters.fnt.create orelse return error.TLSFailure;
        const free_tls = parameters.fnt.free orelse return error.TLSFailure;

        const ca_path_plain = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}",
            .{
                parameters.caches_directory,
                if (std.mem.endsWith(u8, parameters.caches_directory, "/")) "" else "/",
                TLSConstants.ca_filename,
            },
        );
        defer allocator.free(ca_path_plain);
        const ca_path = try allocator.dupeZ(u8, ca_path_plain);
        errdefer allocator.free(ca_path);
        try writeCA(ca_path, ca.pem);
        errdefer _ = c_common.remove(ca_path.ptr);

        const cert_pem = if (configuration.client_certificate) |value|
            try allocator.dupeZ(u8, value.pem)
        else
            null;
        defer if (cert_pem) |value| allocator.free(value);
        const key_pem = if (configuration.client_key) |value|
            try allocator.dupeZ(u8, value.pem)
        else
            null;
        defer if (key_pem) |value| allocator.free(value);
        const hostname = if (configuration.san_host) |value|
            try allocator.dupeZ(u8, value)
        else
            null;
        defer if (hostname) |value| allocator.free(value);

        const verification_context = try allocator.create(VerificationContext);
        errdefer allocator.destroy(verification_context);
        verification_context.* = .{ .verification = parameters.verification };

        const options = c_crypto.pp_tls_options_create(
            configuration.tls_security_level orelse TLSConstants.default_security_level,
            TLSConstants.buffer_length,
            configuration.checks_eku orelse false,
            configuration.checks_san_host orelse false,
            ca_path.ptr,
            if (cert_pem) |value| value.ptr else null,
            if (key_pem) |value| value.ptr else null,
            if (hostname) |value| value.ptr else null,
            verificationFailed,
            verification_context,
        );
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const tls = create_tls(options, &code) orelse {
            c_crypto.pp_tls_options_free(options);
            if (code == c_crypto.PPTLSErrorNone) return error.TLSFailure;
            return errors.tlsError(code);
        };
        errdefer free_tls(tls);

        const self = try allocator.create(TLSWrapper);
        self.* = .{
            .allocator = allocator,
            .fnt = parameters.fnt,
            .tls = tls,
            .ca_path = ca_path,
            .verification_context = verification_context,
        };
        return self;
    }

    pub fn destroy(self: *TLSWrapper) void {
        const allocator = self.allocator;
        self.fnt.free.?(self.tls);
        allocator.destroy(self.verification_context);
        _ = c_common.remove(self.ca_path.ptr);
        allocator.free(self.ca_path);
        allocator.destroy(self);
    }

    pub fn start(self: *TLSWrapper) anyerror!void {
        const start_tls = self.fnt.start orelse return error.TLSFailure;
        if (!start_tls(self.tls)) return error.TLSFailure;
    }

    pub fn isConnected(self: *const TLSWrapper) bool {
        const is_connected = self.fnt.is_connected orelse return false;
        return is_connected(self.tls);
    }

    pub fn putPlainText(self: *TLSWrapper, text: []const u8) anyerror!void {
        return self.putPlain(text);
    }

    pub fn putRawPlainText(self: *TLSWrapper, text: []const u8) anyerror!void {
        return self.putPlain(text);
    }

    pub fn putCipherText(self: *TLSWrapper, data: []const u8) anyerror!void {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const put_cipher = self.fnt.put_cipher orelse return error.TLSFailure;
        if (!put_cipher(self.tls, data.ptr, data.len, &code))
            return tlsOperationError(code);
    }

    pub fn pullPlainText(
        self: *TLSWrapper,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const pull_plain = self.fnt.pull_plain orelse return error.TLSFailure;
        const data = pull_plain(self.tls, &code) orelse {
            if (code == c_crypto.PPTLSErrorNone) return error.TLSNoData;
            return tlsOperationError(code);
        };
        defer c_crypto.pp_zd_free(data);
        return allocator.dupe(u8, data.*.bytes[0..data.*.length]);
    }

    pub fn pullCipherText(
        self: *TLSWrapper,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const pull_cipher = self.fnt.pull_cipher orelse return error.TLSFailure;
        const data = pull_cipher(self.tls, &code) orelse {
            if (code == c_crypto.PPTLSErrorNone) return error.TLSNoData;
            return tlsOperationError(code);
        };
        defer c_crypto.pp_zd_free(data);
        return allocator.dupe(u8, data.*.bytes[0..data.*.length]);
    }

    pub fn caMD5(
        self: *TLSWrapper,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const ca_md5 = self.fnt.ca_md5 orelse return error.TLSFailure;
        const value = ca_md5(self.tls) orelse return error.TLSFailure;
        defer c_common.pp_free(value);
        return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(value))));
    }

    fn putPlain(self: *TLSWrapper, data: []const u8) anyerror!void {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const put_plain = self.fnt.put_plain orelse return error.TLSFailure;
        if (!put_plain(self.tls, data.ptr, data.len, &code))
            return tlsOperationError(code);
    }

    fn verificationFailed(context: ?*anyopaque) callconv(.c) void {
        const typed: *VerificationContext = @ptrCast(@alignCast(context orelse return));
        typed.verification.failed();
    }

    fn writeCA(path: [:0]const u8, pem: []const u8) anyerror!void {
        const file = c_common.fopen(path.ptr, "wb") orelse return error.TLSFailure;
        defer _ = c_common.fclose(file);
        if (pem.len == 0) return;
        if (c_common.fwrite(pem.ptr, 1, pem.len, file) != pem.len) return error.TLSFailure;
    }

    fn tlsOperationError(code: c_crypto.pp_tls_error_code) anyerror {
        if (code == c_crypto.PPTLSErrorNone) return error.TLSFailure;
        return errors.tlsError(code);
    }
};

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
    const caches_directory = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer allocator.free(caches_directory);

    var verification_failures: usize = 0;
    const configuration = api.OpenVPNConfiguration{
        .ca = .{ .pem = "-----BEGIN CERTIFICATE-----\nmock\n-----END CERTIFICATE-----\n" },
    };
    var fnt = c_crypto.pp_crypto_fnt_mock().tls;
    fnt.create = Fake.create;
    fnt.free = Fake.free;
    fnt.start = Fake.start;
    fnt.is_connected = Fake.isConnected;
    fnt.pull_plain = Fake.pullPlain;
    fnt.pull_cipher = Fake.pullCipher;
    fnt.put_plain = Fake.put;
    fnt.put_cipher = Fake.put;
    fnt.ca_md5 = Fake.caMD5;
    const tls = try TLSWrapper.create(allocator, .{
        .fnt = fnt,
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
