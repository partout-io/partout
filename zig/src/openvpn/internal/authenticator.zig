// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const configuration_helpers = @import("configuration_helpers.zig");
const ControlChannel = @import("control_channel_constants.zig").ControlChannel;
const Handshake = @import("handshake.zig").Handshake;
const Keys = @import("key_constants.zig").Keys;
const platform = @import("platform_helpers.zig");
const PRNG = @import("prng.zig").PRNG;
const ServerOCC = @import("server_occ.zig").ServerOCC;
const TLSProtocol = @import("tls_protocol.zig").TLSProtocol;
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

const api = core.api;

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
        tls: TLSProtocol,
        configuration: api.OpenVPNConfiguration,
    ) anyerror!void {
        const allocator = self.allocator;
        var raw = try ZeroingData.initCopy(allocator, &ControlChannel.tls_prefix);
        defer raw.deinit(allocator);

        raw.appendData(self.pre_master);
        raw.appendData(self.random1);
        raw.appendData(self.random2);

        const local_options = try configuration_helpers.localOptionsStringAlloc(
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

        const negotiated = try configuration_helpers.negotiableDataCiphers(
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
        const platform_version = try platform.versionAlloc(allocator);
        defer allocator.free(platform_version);
        const peer_info = try ControlChannel.peerInfoAlloc(
            allocator,
            "io.partout 0.151.0",
            self.ssl_version,
            platform.name(),
            platform_version,
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
        const prefix_length = ControlChannel.tls_prefix.len;
        const minimum_length = prefix_length + 2 * Keys.random_length + 2;
        if (self.control_buffer.bytes.len < minimum_length) return false;
        if (!std.mem.eql(
            u8,
            self.control_buffer.bytes[0..prefix_length],
            &ControlChannel.tls_prefix,
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
    /// outer slice and must call `freeMessages`.
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

    pub fn freeMessages(allocator: std.mem.Allocator, messages: [][]u8) void {
        for (messages) |message| allocator.free(message);
        allocator.free(messages);
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

        fn protocol(self: *Self) TLSProtocol {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn cast(pointer: *anyopaque) *Self {
            return @ptrCast(@alignCast(pointer));
        }

        fn start(_: *anyopaque) anyerror!void {}

        fn isConnected(_: *anyopaque) bool {
            return true;
        }

        fn put(pointer: *anyopaque, data: []const u8) anyerror!void {
            const self = cast(pointer);
            if (self.plaintext) |value| self.allocator.free(value);
            self.plaintext = try self.allocator.dupe(u8, data);
        }

        fn pull(_: *anyopaque, _: std.mem.Allocator) anyerror![]u8 {
            return error.TLSNoData;
        }

        fn caMD5(_: *anyopaque, allocator_: std.mem.Allocator) anyerror![]u8 {
            return allocator_.dupe(u8, "md5");
        }

        fn deinit(_: *anyopaque) void {}

        const vtable = TLSProtocol.VTable{
            .start = start,
            .is_connected = isConnected,
            .put_plain_text = put,
            .put_raw_plain_text = put,
            .put_cipher_text = put,
            .pull_plain_text = pull,
            .pull_cipher_text = pull,
            .ca_md5 = caMD5,
            .deinit = deinit,
        };
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
    try authenticator.putAuth(recorder.protocol(), .{
        .cipher = .aes256gcm,
        .data_ciphers = &ciphers,
        .digest = .sha256,
    });
    const framed = recorder.plaintext.?;
    try std.testing.expectEqualSlices(
        u8,
        &ControlChannel.tls_prefix,
        framed[0..ControlChannel.tls_prefix.len],
    );
    try std.testing.expect(framed.len >
        ControlChannel.tls_prefix.len + Keys.pre_master_length + 2 * Keys.random_length);
    try std.testing.expect(std.mem.indexOf(u8, framed, "IV_PLAT_VER=") != null);

    const server_options = "V4,cipher AES-256-GCM,auth SHA256\x00";
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);
    try reply.appendSlice(allocator, &ControlChannel.tls_prefix);
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
    defer Authenticator.freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("AUTH_FAILED", messages[0]);
    try std.testing.expectEqualStrings("PUSH_REPLY,route", messages[1]);
    try std.testing.expectEqualStrings("partial", authenticator.control_buffer.bytes);
}
