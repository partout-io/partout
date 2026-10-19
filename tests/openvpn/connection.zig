// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const builtin = @import("builtin");
const source = @import("source");

const core = source.core;
const connection = source.openvpn_connection;
const mock = source.mock;
const net = source.net;
const io = source.net_io;

const api = core.api;

test "OpenVPN preserves authentication for reconnect and rebind shutdown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Request = struct {
        created: net.Connection,
        reason: net.Connection.ShutdownReason,
        rebind_events: usize = 0,
        unexpected_events: usize = 0,

        fn run(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const concrete: *connection.testing.Implementation = @ptrCast(@alignCast(self.created.ptr));
            // Model a token from PUSH_REPLY and a successful local-options
            // fallback, followed by a daemon-originated setup failure.
            concrete.auth_token.update("server-issued-token");
            concrete.with_local_options = false;
            try std.testing.expect(concrete.pending_failure == null);
            try std.testing.expect(!concrete.pending_rebind);
            if (self.reason == .rebind) {
                const sink = net.Connection.Events{
                    .ctx = self,
                    .event = recordEvent,
                };
                concrete.events = sink;
                const internal = source.openvpn_internal;
                const endpoint = try net.SocketEndpoint.init(api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?);
                const session = try internal.session.Session.create(std.testing.allocator, .{
                    .writer = concrete.writer.?,
                    .remote_endpoint = endpoint,
                    .events = concrete.session_events,
                    .configuration = .{},
                    .credentials = null,
                    .auth_token = &concrete.auth_token,
                    .prng = internal.crypto.PRNG.system(),
                    .caches_directory = "",
                    .ca_filename = "",
                    .options = .{ .backend = .mock },
                });
                concrete.current_session = session;
                // Model an established session without a server handshake.
                const data_link = internal.data.DataLink.init(std.testing.allocator, endpoint, session.link_processor, self, .{
                    .write_packets = writeData,
                    .data_channel = noChannel,
                    .report_inbound_data_count = ignoreDataSize,
                    .report_outbound_data_count = ignoreDataSize,
                });
                session.state = .{ .active = .{
                    .phase = .started,
                    .context = try internal.session_context.ActiveContext.create(std.testing.allocator, data_link, false, endpoint),
                } };
                self.created.betterPath(sink);
                self.created.betterPath(sink);
                try std.testing.expect(concrete.pending_rebind);
                try std.testing.expect(concrete.pending_failure == null);
                try std.testing.expectEqual(@as(usize, 1), self.rebind_events);
                self.unexpected_events = 0;
                try std.testing.expectEqual(net.ReadAction.pause, self.created.submitPackets(.link, &.{"invalid"}, null));
                try std.testing.expectEqual(net.ReadAction.pause, self.created.submitPackets(.tun, &.{"invalid"}, null));
                concrete.session_events.established(concrete.session_events.ctx, session.remote_endpoint, &.{});
                concrete.session_events.failed(concrete.session_events.ctx, error.LinkFailure);
                try std.testing.expectEqual(@as(usize, 0), self.unexpected_events);
                try std.testing.expect(concrete.pending_failure == null);
                concrete.events = null;
            }
            self.created.shutdown(self.reason);
            self.created.stop(0, .{
                .ctx = self,
                .event = recordEvent,
            });

            try std.testing.expect(!concrete.pending_rebind);
            var token = concrete.auth_token.copy();
            defer if (token) |*value| value.deinit();
            const reconnecting = self.reason == .rebind or
                (self.reason == .failure and self.reason.failure == .reconnect);
            try std.testing.expectEqual(!reconnecting, concrete.with_local_options);
            if (reconnecting) {
                try std.testing.expect(token != null);
                try std.testing.expectEqualStrings("server-issued-token", token.?.asSlice());
            } else {
                try std.testing.expect(token == null);
            }
        }

        fn recordEvent(raw: *anyopaque, event: net.Connection.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .needs_rebind => self.rebind_events += 1,
                else => self.unexpected_events += 1,
            }
        }
        fn writeData(_: ?*anyopaque, _: net.Packets, _: net.Side, _: ?net.SocketAddress) (net.SubmissionError || error{MissingDestination})!void {}
        fn noChannel(_: ?*anyopaque, _: u8) ?*source.openvpn_internal.data.DataChannel {
            return null;
        }
        fn ignoreDataSize(_: ?*anyopaque, _: usize) void {}
        fn writePackets(_: *anyopaque, _: net.Packets, _: net.Side, _: ?net.SocketAddress) (net.SubmissionError || error{MissingDestination})!void {}
        fn scheduleTimer(_: *anyopaque, _: *net.Timer, _: u64, _: io.TimedTask) net.SubmissionError!void {}
        fn cancelTimer(_: *anyopaque, _: *net.Timer) void {}
        const writer_vtable = net.ConnectionWriter.VTable{
            .write_packets = writePackets,
            .schedule_timer = scheduleTimer,
            .cancel_timer = cancelTimer,
        };
    };
    const allocator = std.testing.allocator;
    const remotes = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
    const module_id: api.UUID = "11111111-1111-4111-8111-111111111111".*;
    const modules = [_]api.TaggedModule{.{ .OpenVPN = .{
        .id = module_id,
        .configuration = .{ .remotes = &remotes },
    } }};
    const profile = api.Profile{
        .id = "22222222-2222-4222-8222-222222222222".*,
        .name = "OpenVPN",
        .modules = &modules,
        .active_modules_ids = &.{module_id},
    };
    var context = connection.ConnectionContext{ .session_options = .{ .backend = .mock } };
    var controller = mock.MockTunnelController{};
    const created = try connection.createConnection(
        &context,
        allocator,
        source.net_connection.activeConnectionModule(&profile).?,
        .{
            .profile = &profile,
            .controller = controller.interface(),
            .resolver = mock.noopDNSResolver(),
            .factory = mock.noopSocketFactory(),

            .cache_dir = "/tmp",
            .writer = net.ConnectionWriter.init(&controller, &Request.writer_vtable),
        },
    );
    defer created.destroy();
    for ([_]net.Connection.ShutdownReason{
        .{ .failure = .reconnect },
        .rebind,
        .explicit_stop,
        .{ .failure = .cancel },
    }) |reason| {
        var request = Request{ .created = created, .reason = reason };
        try Request.run(&request);
    }
}

test "OpenVPN connection declarations are semantically analyzed" {
    std.testing.refAllDecls(connection);
}

test "OpenVPN connection failure dispositions" {
    const isRecoverableError = connection.testing.isRecoverableError;

    try std.testing.expect(!isRecoverableError(error.BadCredentials));
    try std.testing.expect(!isRecoverableError(error.CompressionMismatch));
    try std.testing.expect(!isRecoverableError(error.InvalidPushReply));
    try std.testing.expect(!isRecoverableError(error.NoRouting));
    try std.testing.expect(!isRecoverableError(error.TLSFailure));
    try std.testing.expect(!isRecoverableError(error.UnsupportedAlgorithm));
    try std.testing.expect(!isRecoverableError(error.UnsupportedCompression));
    try std.testing.expect(!isRecoverableError(error.UnsupportedCryptoBackend));

    try std.testing.expect(isRecoverableError(error.BadCredentialsWithLocalOptions));
    try std.testing.expect(isRecoverableError(error.LinkFailure));
    try std.testing.expect(isRecoverableError(error.OutOfMemory));
    try std.testing.expect(isRecoverableError(error.ServerShutdown));
    try std.testing.expect(isRecoverableError(error.TunNotAvailable));

    {
        const implementation = connection;
        inline for (.{ error.InvalidSocketMode, error.InvalidOffset, error.InvalidAddressFamily, error.MissingDestination }) |err| {
            try std.testing.expect(!implementation.testing.isRecoverableError(err));
        }
    }
}

test "OpenVPN failures separate protocol subcodes from general codes" {
    {
        const implementation = connection;
        const codeForError = implementation.testing.codeForError;
        const protocol_cases = .{
            .{ error.BadCredentialsWithLocalOptions, api.OpenVPNErrorCode.recoverableAuthentication },
            .{ error.CompressionMismatch, api.OpenVPNErrorCode.compressionMismatch },
            .{ error.NoRouting, api.OpenVPNErrorCode.noRouting },
            .{ error.ServerShutdown, api.OpenVPNErrorCode.serverShutdown },
            .{ error.TLSFailure, api.OpenVPNErrorCode.tlsFailure },
            .{ error.CryptoDerivation, api.OpenVPNErrorCode.unsupportedAlgorithm },
            .{ error.UnsupportedAlgorithm, api.OpenVPNErrorCode.unsupportedAlgorithm },
            .{ error.UnsupportedCompression, api.OpenVPNErrorCode.unsupportedCompression },
            .{ error.LinkFailure, api.OpenVPNErrorCode.connectionFailure },
        };
        inline for (protocol_cases) |entry| {
            const result = codeForError(entry[0]);
            try std.testing.expectEqual(api.PartoutErrorCode.openVPN, result.code);
            try std.testing.expectEqualStrings(entry[1].raw(), result.sub_code.?);
        }
        const generic_cases = .{
            .{ error.BadCredentials, api.PartoutErrorCode.authentication },
            .{ error.CryptoEncryption, api.PartoutErrorCode.crypto },
            .{ error.InvalidEndpoint, api.PartoutErrorCode.invalidValue },
            .{ error.InvalidSocketMode, api.PartoutErrorCode.invalidValue },
            .{ error.InvalidOffset, api.PartoutErrorCode.invalidValue },
            .{ error.InvalidAddressFamily, api.PartoutErrorCode.invalidValue },
            .{ error.MissingDestination, api.PartoutErrorCode.invalidValue },
            .{ error.MuxFailure, api.PartoutErrorCode.fdUnavailable },
            .{ error.Timeout, api.PartoutErrorCode.timeout },
            .{ error.TunNotAvailable, api.PartoutErrorCode.tunNotAvailable },
        };
        inline for (generic_cases) |entry| {
            const result = codeForError(entry[0]);
            try std.testing.expectEqual(entry[1], result.code);
            try std.testing.expectEqual(@as(?[]const u8, null), result.sub_code);
        }
    }
}

test "unconnected OpenVPN accepts only the selected IPv4 or scoped IPv6 peer" {
    const matches = source.openvpn_connection.testing.peerSourceMatches;
    for ([_][]const u8{ "192.0.2.1", "fe80::1%7" }) |address| {
        const peer = (try net.SocketEndpoint.init(.{ .address = address, .proto = .init(.udp, 1194) })).address;
        try std.testing.expect(matches(peer, peer));
        var other = peer;
        other.port += 1;
        try std.testing.expect(!matches(other, peer));
        other = peer;
        other.address[0] ^= 1;
        try std.testing.expect(!matches(other, peer));
        other = peer;
        other.family = if (peer.family == 4) 6 else 4;
        try std.testing.expect(!matches(other, peer));
        other = peer;
        other.scope_id += 1;
        try std.testing.expect(!matches(other, peer));
    }
}
