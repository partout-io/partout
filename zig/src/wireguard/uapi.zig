// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const api = core.api;

const resolver = @import("resolver.zig");

pub const BuildConfigurationError = std.Io.Writer.Error || api.EncodeError;

pub fn buildConfiguration(
    allocator: std.mem.Allocator,
    configuration: *const api.WireGuardConfiguration,
    resolved_endpoints: []const resolver.ResolvedEndpoint,
) BuildConfigurationError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    const private_key = try configuration.interface.private_key.hexAlloc(allocator);
    defer allocator.free(private_key);
    try writer.print("private_key={s}\n", .{private_key});
    if (configuration.interface.listen_port) |listen_port| {
        try writer.print("listen_port={}\n", .{listen_port});
    }
    if (configuration.peers.len > 0) try writer.writeAll("replace_peers=true\n");

    for (configuration.peers) |*peer| {
        const public_key = try peer.public_key.hexAlloc(allocator);
        defer allocator.free(public_key);
        try writer.print("public_key={s}\n", .{public_key});

        if (peer.pre_shared_key) |psk_value| {
            if (psk_value.raw.len > 0) {
                const psk = try psk_value.hexAlloc(allocator);
                defer allocator.free(psk);
                try writer.print("preshared_key={s}\n", .{psk});
            }
        }

        if (peer.endpoint) |endpoint| {
            if (resolvedEndpoint(resolved_endpoints, endpoint)) |resolved| {
                const endpoint_text = try resolved.rawAlloc(allocator);
                defer allocator.free(endpoint_text);
                try writer.print("endpoint={s}\n", .{endpoint_text});
            }
        }

        try writer.print("persistent_keepalive_interval={}\n", .{peer.keep_alive orelse 0});

        if (peer.allowed_ips.len > 0) {
            try writer.writeAll("replace_allowed_ips=true\n");
            for (peer.allowed_ips) |allowed_ip| {
                const raw = try allowed_ip.rawAlloc(allocator);
                defer allocator.free(raw);
                if (raw.len == 0) continue;
                try writer.print("allowed_ip={s}\n", .{raw});
            }
        }
    }

    return aw.toOwnedSlice();
}

pub fn buildEndpointConfiguration(
    allocator: std.mem.Allocator,
    configuration: *const api.WireGuardConfiguration,
    resolved_endpoints: []const resolver.ResolvedEndpoint,
) BuildConfigurationError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    for (configuration.peers) |*peer| {
        const public_key = try peer.public_key.hexAlloc(allocator);
        defer allocator.free(public_key);
        try writer.print("public_key={s}\n", .{public_key});

        const endpoint = peer.endpoint orelse continue;
        const resolved = resolvedEndpoint(resolved_endpoints, endpoint) orelse continue;
        const endpoint_text = try resolved.rawAlloc(allocator);
        defer allocator.free(endpoint_text);
        try writer.print("endpoint={s}\n", .{endpoint_text});
    }

    return aw.toOwnedSlice();
}

pub fn parseRuntimeDataCount(text: []const u8) ?api.DataCount {
    var received: ?u64 = null;
    var sent: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (received == null and std.mem.startsWith(u8, line, "rx_bytes=")) {
            received = std.fmt.parseInt(u64, line["rx_bytes=".len..], 10) catch null;
        } else if (sent == null and std.mem.startsWith(u8, line, "tx_bytes=")) {
            sent = std.fmt.parseInt(u64, line["tx_bytes=".len..], 10) catch null;
        }
        if (received != null and sent != null) break;
    }
    return .{
        .received = received orelse return null,
        .sent = sent orelse return null,
    };
}

fn resolvedEndpoint(
    map: []const resolver.ResolvedEndpoint,
    source: api.Endpoint,
) ?api.Endpoint {
    for (map) |entry| {
        if (entry.source.eql(source)) return entry.target;
    }
    return null;
}
