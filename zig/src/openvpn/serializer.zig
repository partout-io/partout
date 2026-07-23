// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const api = core.api;

pub fn serializeModule(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: *const api.TaggedModule,
    _: ?*anyopaque,
) core.SerializeError![]u8 {
    // ZIGME: Make Configuration non-optional in OpenAPI and remove .IncompleteModule
    const configuration = switch (module.*) {
        .OpenVPN => |*openvpn| blk: {
            const value = if (openvpn.configuration) |*configuration|
                configuration
            else
                return error.IncompleteModule;
            break :blk value;
        },
        else => return error.UnexpectedModuleType,
    };
    return serializeConfiguration(allocator, configuration);
}

pub fn serializeConfiguration(
    allocator: std.mem.Allocator,
    configuration: *const api.OpenVPNConfiguration,
) core.SerializeError![]u8 {
    if (configuration.static_challenge orelse false) return error.SerializationFailed;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var output = ConfigurationWriter{ .writer = &aw.writer };

    try output.line("client", .{});
    try output.line("dev tun", .{});
    try output.line("nobind", .{});
    try output.line("persist-key", .{});
    try output.line("persist-tun", .{});

    const data_ciphers = configuration.data_ciphers orelse &.{};
    if (data_ciphers.len > 0) {
        try output.beginLine();
        try output.writeAll("data-ciphers ");
        for (data_ciphers, 0..) |cipher, index| {
            if (index > 0) try output.writeAll(":");
            try output.writeAll(cipher.raw());
        }
        if (configuration.cipher) |cipher| {
            try output.line("data-ciphers-fallback {s}", .{cipher.raw()});
        }
    } else if (configuration.cipher) |cipher| {
        try output.line("cipher {s}", .{cipher.raw()});
    }

    if (configuration.digest) |digest| try output.line("auth {s}", .{digest.raw()});
    try output.compression(configuration.compression_framing, configuration.compression_algorithm);

    const keep_alive_interval = try optionalSeconds(configuration.keep_alive_interval);
    const keep_alive_timeout = try optionalSeconds(configuration.keep_alive_timeout);
    if (keep_alive_interval != null and keep_alive_timeout != null) {
        try output.line("keepalive {} {}", .{ keep_alive_interval.?, keep_alive_timeout.? });
    } else {
        if (keep_alive_interval) |seconds| try output.line("ping {}", .{seconds});
        if (keep_alive_timeout) |seconds| try output.line("ping-restart {}", .{seconds});
    }
    if (try optionalSeconds(configuration.renegotiates_after)) |seconds| {
        try output.line("reneg-sec {}", .{seconds});
    }

    if (configuration.checks_eku orelse false) try output.line("remote-cert-tls server", .{});
    if ((configuration.checks_san_host orelse false) and configuration.san_host != null) {
        try output.line("verify-x509-name {s} name", .{configuration.san_host.?});
    }
    if (configuration.randomize_endpoint orelse false) try output.line("remote-random", .{});
    if (configuration.randomize_hostnames orelse false) try output.line("remote-random-hostname", .{});
    if (configuration.mtu) |mtu| try output.line("tun-mtu {}", .{mtu});

    if (configuration.remotes) |remotes| {
        for (remotes) |remote| {
            try output.line("remote {s} {} {s}", .{
                remote.address,
                remote.proto.port,
                socketTypeRaw(remote.proto.socket_type),
            });
        }
    }

    if (configuration.auth_user_pass orelse false) try output.line("auth-user-pass", .{});
    if (configuration.auth_token) |token| try output.line("auth-token {s}", .{token});
    if (configuration.peer_id) |peer_id| try output.line("peer-id {}", .{peer_id});
    if (configuration.routing_policies) |policies| try output.routingPolicies(policies);

    if (configuration.route_gateway4) |gateway| try output.line("route-gateway {s}", .{gateway.raw});
    if (configuration.route_gateway6) |gateway| try output.line("route-ipv6-gateway {s}", .{gateway.raw});

    if (configuration.dns_servers) |servers| {
        for (servers) |server| try output.line("dhcp-option DNS {s}", .{server});
    }
    if (configuration.dns_domain) |domain| try output.line("dhcp-option DOMAIN {s}", .{domain});
    if (configuration.search_domains) |domains| {
        for (domains) |domain| try output.line("dhcp-option DOMAIN-SEARCH {s}", .{domain});
    }
    if (configuration.http_proxy) |proxy| {
        try output.line("dhcp-option PROXY_HTTP {s} {}", .{ proxy.address, proxy.port });
    }
    if (configuration.https_proxy) |proxy| {
        try output.line("dhcp-option PROXY_HTTPS {s} {}", .{ proxy.address, proxy.port });
    }
    if (configuration.proxy_auto_configuration_url) |url| {
        try output.line("dhcp-option PROXY_AUTO_CONFIG_URL {s}", .{url});
    }
    if (configuration.proxy_bypass_domains) |domains| try output.proxyBypass(domains);

    if (configuration.routes4) |routes| {
        for (routes) |route| try output.route(allocator, route);
    }
    if (configuration.routes6) |routes| {
        for (routes) |route| try output.route(allocator, route);
    }

    if (configuration.xor_method) |method| try output.xorMethod(allocator, method);
    if (configuration.ca) |ca| try output.block("ca", ca.pem);
    if (configuration.client_certificate) |certificate| try output.block("cert", certificate.pem);
    if (configuration.client_key) |key| try output.block("key", key.pem);
    if (configuration.tls_wrap) |wrap| try output.tlsWrap(allocator, wrap);

    return aw.toOwnedSlice();
}

const ConfigurationWriter = struct {
    writer: *std.Io.Writer,
    has_lines: bool = false,

    fn beginLine(self: *ConfigurationWriter) core.SerializeError!void {
        if (self.has_lines) self.writer.writeByte('\n') catch return error.OutOfMemory;
        self.has_lines = true;
    }

    fn writeAll(self: *const ConfigurationWriter, text: []const u8) core.SerializeError!void {
        self.writer.writeAll(text) catch return error.OutOfMemory;
    }

    fn print(
        self: *const ConfigurationWriter,
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

    fn block(self: *ConfigurationWriter, tag: []const u8, contents: []const u8) core.SerializeError!void {
        try self.line("<{s}>", .{tag});
        try self.line("{s}", .{contents});
        try self.line("</{s}>", .{tag});
    }

    fn compression(
        self: *ConfigurationWriter,
        framing: ?api.OpenVPNCompressionFraming,
        algorithm: ?api.OpenVPNCompressionAlgorithm,
    ) core.SerializeError!void {
        const value = framing orelse return;
        switch (value) {
            .compLZO => if (algorithm) |inner| switch (inner) {
                .LZO => try self.line("comp-lzo", .{}),
                .disabled => try self.line("comp-lzo no", .{}),
                .other => {},
            },
            .compress => if (algorithm) |inner| switch (inner) {
                .LZO => try self.line("compress lzo", .{}),
                .disabled => try self.line("compress stub", .{}),
                .other => {},
            },
            .compressV2 => try self.line("compress stub-v2", .{}),
            .disabled => {},
        }
    }

    fn routingPolicies(
        self: *ConfigurationWriter,
        policies: []const api.OpenVPNRoutingPolicy,
    ) core.SerializeError!void {
        if (policies.len == 0) return;

        var has_ipv4 = false;
        var has_ipv6 = false;
        var blocks_local = false;
        for (policies) |policy| switch (policy) {
            .IPv4 => has_ipv4 = true,
            .IPv6 => has_ipv6 = true,
            .blockLocal => blocks_local = true,
        };

        try self.beginLine();
        try self.writeAll("redirect-gateway");
        if (!has_ipv4) try self.writeAll(" !ipv4");
        if (has_ipv6) try self.writeAll(" ipv6");
        if (blocks_local) try self.writeAll(" block-local");
    }

    fn proxyBypass(
        self: *ConfigurationWriter,
        domains: []const []const u8,
    ) core.SerializeError!void {
        if (domains.len == 0) return;
        try self.beginLine();
        try self.writeAll("dhcp-option PROXY_BYPASS ");
        for (domains, 0..) |domain, index| {
            if (index > 0) try self.writeAll(" ");
            try self.writeAll(domain);
        }
    }

    fn route(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        value: api.Route,
    ) core.SerializeError!void {
        const destination = value.destination orelse return;
        switch (destination.address.family) {
            .v4 => {
                const mask = destination.ipv4MaskAlloc(allocator) catch |err| return mapEncodeError(err);
                defer allocator.free(mask);
                if (value.gateway) |gateway| {
                    try self.line("route {s} {s} {s}", .{ destination.address.raw, mask, gateway.raw });
                } else {
                    try self.line("route {s} {s}", .{ destination.address.raw, mask });
                }
            },
            .v6 => {
                const raw = destination.rawAlloc(allocator) catch return error.OutOfMemory;
                defer allocator.free(raw);
                if (value.gateway) |gateway| {
                    try self.line("route-ipv6 {s} {s}", .{ raw, gateway.raw });
                } else {
                    try self.line("route-ipv6 {s}", .{raw});
                }
            },
            .hostname => return error.SerializationFailed,
        }
    }

    fn xorMethod(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        method: api.OpenVPNObfuscationMethod,
    ) core.SerializeError!void {
        switch (method) {
            .xormask => |value| try self.xorMask(allocator, "xormask", value.mask),
            .xorptrpos => try self.line("scramble xorptrpos", .{}),
            .reverse => try self.line("scramble reverse", .{}),
            .obfuscate => |value| try self.xorMask(allocator, "obfuscate", value.mask),
        }
    }

    fn xorMask(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        name: []const u8,
        mask: api.SecureData,
    ) core.SerializeError!void {
        const bytes = mask.bytesAlloc(allocator) catch |err| return mapEncodeError(err);
        defer allocator.free(bytes);
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.SerializationFailed;
        try self.line("scramble {s} {s}", .{ name, bytes });
    }

    fn tlsWrap(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        wrap: api.OpenVPNTLSWrap,
    ) core.SerializeError!void {
        const tag = switch (wrap.strategy) {
            .auth => "tls-auth",
            .crypt => "tls-crypt",
            .cryptV2 => "tls-crypt-v2",
        };
        if (wrap.strategy == .auth) {
            if (wrap.key.dir) |direction| try self.line("key-direction {}", .{direction.raw()});
        }

        try self.line("<{s}>", .{tag});
        switch (wrap.strategy) {
            .auth, .crypt => try self.staticKey(allocator, wrap.key),
            .cryptV2 => try self.cryptV2Key(allocator, wrap),
        }
        try self.line("</{s}>", .{tag});
    }

    fn staticKey(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) core.SerializeError!void {
        const hex = key.data.hexAlloc(allocator) catch |err| return mapEncodeError(err);
        defer allocator.free(hex);
        if (hex.len != 512) return error.SerializationFailed;

        try self.line("# 2048 bit OpenVPN static key", .{});
        try self.line("-----BEGIN OpenVPN Static key V1-----", .{});
        var offset: usize = 0;
        while (offset < hex.len) : (offset += 32) {
            try self.line("{s}", .{hex[offset..@min(offset + 32, hex.len)]});
        }
        try self.line("-----END OpenVPN Static key V1-----", .{});
    }

    fn cryptV2Key(
        self: *ConfigurationWriter,
        allocator: std.mem.Allocator,
        wrap: api.OpenVPNTLSWrap,
    ) core.SerializeError!void {
        const key = wrap.key.data.bytesAlloc(allocator) catch |err| return mapEncodeError(err);
        defer allocator.free(key);
        if (key.len != 256) return error.SerializationFailed;

        const wrapped_data = wrap.wrapped_key orelse return error.SerializationFailed;
        const wrapped = wrapped_data.bytesAlloc(allocator) catch |err| return mapEncodeError(err);
        defer allocator.free(wrapped);
        const combined_len = std.math.add(usize, key.len, wrapped.len) catch return error.SerializationFailed;
        const combined = try allocator.alloc(u8, combined_len);
        defer allocator.free(combined);
        @memcpy(combined[0..key.len], key);
        @memcpy(combined[key.len..], wrapped);

        var encoded = try api.SecureData.initBytesAlloc(allocator, combined);
        defer encoded.deinit(allocator);
        try self.line("-----BEGIN OpenVPN tls-crypt-v2 client key-----", .{});
        var offset: usize = 0;
        while (offset < encoded.base64.len) : (offset += 64) {
            try self.line("{s}", .{encoded.base64[offset..@min(offset + 64, encoded.base64.len)]});
        }
        try self.line("-----END OpenVPN tls-crypt-v2 client key-----", .{});
    }
};

fn optionalSeconds(value: ?f64) core.SerializeError!?i64 {
    const seconds = value orelse return null;
    if (!(seconds > 0)) return null;
    if (!std.math.isFinite(seconds) or seconds >= 0x1p63) return error.SerializationFailed;
    return @intFromFloat(@round(seconds));
}

fn socketTypeRaw(value: api.IPSocketType) []const u8 {
    return switch (value) {
        .udp => "udp",
        .tcp => "tcp",
        .udp4 => "udp4",
        .tcp4 => "tcp4",
        .udp6 => "udp6",
        .tcp6 => "tcp6",
    };
}

fn mapEncodeError(err: api.EncodeError) core.SerializeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SerializationFailed,
    };
}
