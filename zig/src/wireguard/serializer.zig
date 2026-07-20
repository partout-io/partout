// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const api = core.api;

pub fn serializeModule(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: api.TaggedModule,
    _: ?*anyopaque,
) core.SerializeError![]u8 {
    const wireguard = switch (module) {
        .WireGuard => |value| value,
        else => return error.UnexpectedModuleType,
    };
    // ZIGME: Make Configuration non-optional in OpenAPI and remove .IncompleteModule
    const cfg = wireguard.configuration orelse return error.IncompleteModule;
    return serializeConfiguration(allocator, cfg);
}

pub fn serializeConfiguration(
    allocator: std.mem.Allocator,
    configuration: api.WireGuardConfiguration,
) core.SerializeError![]u8 {
    try validateRequiredKey(configuration.interface.private_key);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var output = ConfigurationWriter{ .writer = &aw.writer };

    try output.line("[Interface]", .{});
    try output.line("PrivateKey = {s}", .{configuration.interface.private_key.raw});
    if (configuration.interface.listen_port) |listen_port| {
        try output.line("ListenPort = {}", .{listen_port});
    }
    try output.subnets(allocator, "Address", configuration.interface.addresses);
    if (configuration.interface.dns) |dns| try output.dns(dns);
    if (configuration.interface.mtu) |mtu| try output.line("MTU = {}", .{mtu});

    for (configuration.peers) |peer| {
        try validateRequiredKey(peer.public_key);
        try output.line("[Peer]", .{});
        try output.line("PublicKey = {s}", .{peer.public_key.raw});
        if (peer.pre_shared_key) |key| {
            if (key.raw.len > 0) {
                try validateKey(key);
                try output.line("PresharedKey = {s}", .{key.raw});
            }
        }
        try output.subnets(allocator, "AllowedIPs", peer.allowed_ips);
        if (peer.endpoint) |endpoint| {
            const raw = try endpoint.rawAlloc(allocator);
            defer allocator.free(raw);
            try output.line("Endpoint = {s}", .{raw});
        }
        if (peer.keep_alive) |keep_alive| {
            try output.line("PersistentKeepalive = {}", .{keep_alive});
        }
    }

    return aw.toOwnedSlice();
}

const ConfigurationWriter = struct {
    writer: *std.Io.Writer,
    has_lines: bool = false,

    fn beginLine(self: *ConfigurationWriter) core.SerializeError!void {
        if (self.has_lines) self.writer.writeByte('\n') catch return error.OutOfMemory;
        self.has_lines = true;
    }

    fn writeAll(self: *ConfigurationWriter, text: []const u8) core.SerializeError!void {
        self.writer.writeAll(text) catch return error.OutOfMemory;
    }

    fn print(
        self: *ConfigurationWriter,
        comptime format: []const u8,
        args: anytype,
    ) core.SerializeError!void {
        self.writer.print(format, args) catch return error.OutOfMemory;
    }

    fn line(
        self: *ConfigurationWriter,
        comptime format: []const u8,
        args: anytype,
    ) core.SerializeError!void {
        try self.beginLine();
        try self.print(format, args);
    }

    fn subnets(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        name: []const u8,
        values: []const api.Subnet,
    ) core.SerializeError!void {
        if (values.len == 0) return;

        try self.beginLine();
        try self.print("{s} = ", .{name});
        for (values, 0..) |subnet, index| {
            if (index > 0) try self.writeAll(",");
            const raw = subnet.rawAlloc(allocator) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.SerializationFailed;
            };
            defer allocator.free(raw);
            try self.writeAll(raw);
        }
    }

    fn dns(self: *ConfigurationWriter, configuration: api.DNSModule) core.SerializeError!void {
        const domains = configuration.search_domains orelse &.{};
        if (configuration.servers.len == 0 and domains.len == 0) return;

        for (configuration.servers) |server| {
            if (!server.isIPAddress()) return error.SerializationFailed;
        }
        for (domains) |domain| {
            if (domain.isIPAddress()) return error.SerializationFailed;
        }

        try self.beginLine();
        try self.writeAll("DNS = ");
        var has_entry = false;
        for (configuration.servers) |server| {
            if (has_entry) try self.writeAll(",");
            try self.writeAll(server.raw);
            has_entry = true;
        }
        for (domains) |domain| {
            if (has_entry) try self.writeAll(",");
            try self.writeAll(domain.raw);
            has_entry = true;
        }
    }
};

fn validateRequiredKey(key: api.WireGuardKey) core.SerializeError!void {
    if (key.raw.len == 0) return error.IncompleteModule;
    return validateKey(key);
}

fn validateKey(key: api.WireGuardKey) core.SerializeError!void {
    if (api.WireGuardKey.parseRaw(key.raw) == null) return error.SerializationFailed;
}
