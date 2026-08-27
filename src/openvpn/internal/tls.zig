// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const constants_mod = @import("constants.zig");
const helpers_mod = @import("helpers.zig");

const api = core_mod.api;
const c_common = c_exports_mod.common;
const c_crypto = c_exports_mod.crypto;
const log = core_mod.logging;

const CryptoBackend = api.CryptoBackend;
const TLSConstants = constants_mod.TLS;

/// Borrowed arguments used to create a TLS engine.
pub const TLSParameters = struct {
    backend: CryptoBackend,
    caches_directory: []const u8,
    ca_filename: []const u8,
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

pub const TLSError = std.mem.Allocator.Error || error{TLSFailure};
pub const TLSCreateError =
    TLSError ||
    api.CryptoFunctionTableError ||
    error{MissingCA};

/// C-backed TLS implementation.
///
/// The C TLS object takes ownership of `pp_tls_options` after a successful
/// `create`. The Zig wrapper owns its verification context, CA file path, and
/// the TLS object itself.
pub const TLSWrapper = struct {
    allocator: std.mem.Allocator,
    functions: c_crypto.pp_crypto_tls_fnt,
    tls: c_crypto.pp_tls,
    ca_path: [:0]u8,
    verification_context: *VerificationContext,

    const VerificationContext = struct {
        verification: TLSParameters.Verification,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        parameters: TLSParameters,
    ) TLSCreateError!*TLSWrapper {
        const functions = (try api.cryptoFunctionTable(parameters.backend)).tls;
        return createWithFunctions(
            allocator,
            parameters,
            functions,
        );
    }

    fn createWithFunctions(
        allocator: std.mem.Allocator,
        parameters: TLSParameters,
        functions: c_crypto.pp_crypto_tls_fnt,
    ) TLSCreateError!*TLSWrapper {
        const configuration = parameters.configuration.*;
        const ca = configuration.ca orelse return error.MissingCA;
        const create_tls = functions.create orelse
            @panic("OpenVPN TLS backend does not define create");
        const free_tls = functions.free orelse
            @panic("OpenVPN TLS backend does not define free");

        const ca_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}{s}{s}",
            .{
                parameters.caches_directory,
                if (std.mem.endsWith(u8, parameters.caches_directory, "/")) "" else "/",
                parameters.ca_filename,
            },
            0,
        );
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
            log.writef(.fault, "Unable to create TLS: {d}", .{code});
            return error.TLSFailure;
        };
        errdefer free_tls(tls);

        const self = try allocator.create(TLSWrapper);
        self.* = .{
            .allocator = allocator,
            .functions = functions,
            .tls = tls,
            .ca_path = ca_path,
            .verification_context = verification_context,
        };
        return self;
    }

    pub fn destroy(self: *const TLSWrapper) void {
        const allocator = self.allocator;
        const free_tls = self.functions.free orelse
            @panic("OpenVPN TLS backend does not define free");
        free_tls(self.tls);
        allocator.destroy(self.verification_context);
        _ = c_common.remove(self.ca_path.ptr);
        allocator.free(self.ca_path);
        allocator.destroy(self);
    }

    pub fn start(self: *const TLSWrapper) TLSError!void {
        const start_tls = self.functions.start orelse
            @panic("OpenVPN TLS backend does not define start");
        if (!start_tls(self.tls)) return error.TLSFailure;
    }

    pub fn isConnected(self: *const TLSWrapper) bool {
        const is_connected = self.functions.is_connected orelse
            @panic("OpenVPN TLS backend does not define is_connected");
        return is_connected(self.tls);
    }

    pub fn putPlainText(self: *const TLSWrapper, text: []const u8) TLSError!void {
        return self.putPlain(text);
    }

    pub fn putRawPlainText(self: *const TLSWrapper, text: []const u8) TLSError!void {
        return self.putPlain(text);
    }

    pub fn putCipherText(self: *const TLSWrapper, data: []const u8) TLSError!void {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const put_cipher = self.functions.put_cipher orelse
            @panic("OpenVPN TLS backend does not define put_cipher");
        if (!put_cipher(self.tls, data.ptr, data.len, &code))
            return loggingTLSErrorFromCode(code);
    }

    pub fn pullPlainText(
        self: *const TLSWrapper,
        allocator: std.mem.Allocator,
    ) TLSError!?[]u8 {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const pull_plain = self.functions.pull_plain orelse
            @panic("OpenVPN TLS backend does not define pull_plain");
        const data = pull_plain(self.tls, &code) orelse {
            if (code == c_crypto.PPTLSErrorNone) return null;
            return loggingTLSErrorFromCode(code);
        };
        defer c_crypto.pp_zd_free(data);
        return try allocator.dupe(u8, data.*.bytes[0..data.*.length]);
    }

    pub fn pullCipherText(
        self: *const TLSWrapper,
        allocator: std.mem.Allocator,
    ) TLSError!?[]u8 {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const pull_cipher = self.functions.pull_cipher orelse
            @panic("OpenVPN TLS backend does not define pull_cipher");
        const data = pull_cipher(self.tls, &code) orelse {
            if (code == c_crypto.PPTLSErrorNone) return null;
            return loggingTLSErrorFromCode(code);
        };
        defer c_crypto.pp_zd_free(data);
        return try allocator.dupe(u8, data.*.bytes[0..data.*.length]);
    }

    pub fn caMD5(
        self: *const TLSWrapper,
        allocator: std.mem.Allocator,
    ) (error{CryptoEncryption} || TLSError)![]u8 {
        const ca_md5 = self.functions.ca_md5 orelse
            @panic("OpenVPN TLS backend does not define ca_md5");
        const value = ca_md5(self.tls) orelse return error.CryptoEncryption;
        defer c_common.pp_free(value);
        return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(value))));
    }

    fn putPlain(self: *const TLSWrapper, data: []const u8) !void {
        var code: c_crypto.pp_tls_error_code = c_crypto.PPTLSErrorNone;
        const put_plain = self.functions.put_plain orelse
            @panic("OpenVPN TLS backend does not define put_plain");
        if (!put_plain(self.tls, data.ptr, data.len, &code))
            return loggingTLSErrorFromCode(code);
    }

    fn verificationFailed(context: ?*anyopaque) callconv(.c) void {
        const typed: *VerificationContext = @ptrCast(@alignCast(context orelse return));
        typed.verification.failed();
    }

    fn writeCA(path: [:0]const u8, pem: []const u8) !void {
        const file = c_common.fopen(path.ptr, "wb") orelse return error.MissingCA;
        defer _ = c_common.fclose(file);
        if (pem.len == 0) return;
        if (c_common.fwrite(pem.ptr, 1, pem.len, file) != pem.len) return error.MissingCA;
    }

    pub const testing = struct {
        pub fn createWithFunctions(
            allocator: std.mem.Allocator,
            parameters: TLSParameters,
            functions: c_crypto.pp_crypto_tls_fnt,
        ) !*TLSWrapper {
            return TLSWrapper.createWithFunctions(
                allocator,
                parameters,
                functions,
            );
        }
    };
};

fn loggingTLSErrorFromCode(code: c_crypto.pp_tls_error_code) TLSError {
    log.writef(.fault, "Unable to execute TLS operation: {d}", .{code});
    return error.TLSFailure;
}
