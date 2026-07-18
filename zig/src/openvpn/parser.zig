// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");

const api = core.api;
const util = core.util;

pub fn importModule(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    contents: []const u8,
    context: ?core.ImportContext,
) core.ImportError!api.TaggedModule {
    const parser = Parser{};
    var configuration = parser.parseWithContext(allocator, contents, importParserContext(context)) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidFormat => error.UnknownImportedModule,
            error.EmptyPassphrase => {
                setRecognizedType(context);
                return error.PassphraseRequired;
            },
            else => {
                setRecognizedType(context);
                return error.Parsing;
            },
        };
    };
    setRecognizedType(context);
    const module_id = core.newId() catch {
        configuration.deinit(allocator);
        return error.Parsing;
    };
    const module = api.TaggedModule{ .OpenVPN = .{
        .id = module_id,
        .configuration = configuration,
    } };
    return module;
}

pub const Parser = struct {
    pub const DecryptKey = *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
        []const u8,
    ) anyerror![]u8;

    pub const Context = struct {
        passphrase: ?[]const u8 = null,
        parse_error_info: ?*api.ParseErrorInfo = null,

        fn setLineParseErrorInfo(
            self: Context,
            allocator: std.mem.Allocator,
            line: []const u8,
            err: ParseError,
        ) void {
            switch (err) {
                error.MalformedOption,
                error.UnsupportedCompression,
                error.UnsupportedConfiguration,
                => self.setParseErrorInfo(allocator, lineOptionName(line), line),
                else => {},
            }
        }

        fn setParseErrorInfo(
            self: Context,
            allocator: std.mem.Allocator,
            name: []const u8,
            details: []const u8,
        ) void {
            const info = self.parse_error_info orelse return;
            if (info.name.len != 0 or info.details.len != 0) return;
            const owned_name = allocator.dupe(u8, name) catch return;
            const owned_details = allocator.dupe(u8, details) catch {
                allocator.free(owned_name);
                return;
            };
            info.* = .{
                .name = owned_name,
                .details = owned_details,
            };
        }
    };

    decrypt_key_ctx: ?*anyopaque = null,
    decrypt_key: ?DecryptKey = null,

    pub fn parse(
        allocator: std.mem.Allocator,
        contents: []const u8,
    ) ParseError!api.OpenVPNConfiguration {
        return (Parser{}).parseWithContext(allocator, contents, .{});
    }

    pub fn parseWithContext(
        self: Parser,
        allocator: std.mem.Allocator,
        contents: []const u8,
        context: Context,
    ) ParseError!api.OpenVPNConfiguration {
        var builder = Builder{
            .context = context,
            .decrypt_key_ctx = self.decrypt_key_ctx,
            .decrypt_key = self.decrypt_key,
        };
        defer builder.deinit(allocator);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = util.trim(raw_line);
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            builder.putLine(allocator, line) catch |err| {
                builder.context.setLineParseErrorInfo(allocator, line, err);
                return err;
            };
        }

        return try builder.build(allocator);
    }
};

pub const ParseError = std.mem.Allocator.Error || error{
    ContinuationPushReply,
    DecrypterRequired,
    EmptyPassphrase,
    InvalidFormat,
    MalformedOption,
    UnableToDecrypt,
    UnsupportedCompression,
    UnsupportedConfiguration,
};

const Builder = struct {
    configuration: api.OpenVPNConfiguration = .{},
    data_ciphers: std.ArrayList(api.OpenVPNCipher) = .empty,
    remotes: std.ArrayList(RemoteBuilder) = .empty,
    routes4: std.ArrayList(api.Route) = .empty,
    routes6: std.ArrayList(api.Route) = .empty,
    dns_servers: std.ArrayList([]u8) = .empty,
    search_domains: std.ArrayList([]u8) = .empty,
    proxy_bypass_domains: std.ArrayList([]u8) = .empty,
    routing_policies: std.ArrayList(api.OpenVPNRoutingPolicy) = .empty,
    no_pull_mask: std.ArrayList(api.OpenVPNPullMask) = .empty,
    current_block_name: ?[]u8 = null,
    current_block_lines: std.ArrayList([]u8) = .empty,
    tls_strategy: ?api.OpenVPNTLSWrapStrategy = null,
    tls_key_lines: ?[][]u8 = null,
    tls_key_direction: ?api.OpenVPNStaticKeyDirection = null,
    default_protocol: api.IPSocketType = .udp,
    default_port: u16 = 1194,
    found_option: bool = false,
    context: Parser.Context = .{},
    decrypt_key_ctx: ?*anyopaque = null,
    decrypt_key: ?Parser.DecryptKey = null,

    fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.configuration.deinit(allocator);
        self.data_ciphers.deinit(allocator);
        for (self.remotes.items) |*remote| remote.deinit(allocator);
        self.remotes.deinit(allocator);
        for (self.routes4.items) |*route| route.deinit(allocator);
        self.routes4.deinit(allocator);
        for (self.routes6.items) |*route| route.deinit(allocator);
        self.routes6.deinit(allocator);
        util.deinitListOfStrings(allocator, &self.dns_servers);
        util.deinitListOfStrings(allocator, &self.search_domains);
        util.deinitListOfStrings(allocator, &self.proxy_bypass_domains);
        self.routing_policies.deinit(allocator);
        self.no_pull_mask.deinit(allocator);
        if (self.current_block_name) |value| allocator.free(value);
        util.deinitListOfStrings(allocator, &self.current_block_lines);
        if (self.tls_key_lines) |lines| util.freeSliceOfStrings(allocator, lines);
    }

    fn putLine(
        self: *Builder,
        allocator: std.mem.Allocator,
        line: []const u8,
    ) ParseError!void {
        if (self.current_block_name) |block_name| {
            if (blockEndName(line)) |name| {
                if (std.ascii.eqlIgnoreCase(block_name, name)) {
                    try self.finishBlock(allocator, block_name);
                    allocator.free(block_name);
                    self.current_block_name = null;
                    self.current_block_lines.clearRetainingCapacity();
                    return;
                }
            }
            try util.appendOwned(allocator, &self.current_block_lines, line);
            return;
        }

        if (blockBeginName(line)) |name| {
            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                self.context.setParseErrorInfo(allocator, name, line);
                return error.UnsupportedConfiguration;
            }
            self.current_block_name = try allocator.dupe(u8, name);
            return;
        }

        var components: std.ArrayList([]const u8) = .empty;
        defer components.deinit(allocator);
        var words = std.mem.tokenizeAny(u8, line, " \t");
        while (words.next()) |word| {
            try components.append(allocator, word);
        }
        if (components.items.len == 0) return;

        const option = components.items[0];

        if (std.ascii.eqlIgnoreCase(option, "push-continuation")) {
            self.found_option = true;
            if (components.items.len > 1 and std.mem.eql(u8, components.items[1], "2")) {
                return error.ContinuationPushReply;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "fragment") or std.ascii.endsWithIgnoreCase(option, "-proxy")) {
            self.found_option = true;
            return error.UnsupportedConfiguration;
        }
        if (std.ascii.eqlIgnoreCase(option, "ca") or std.ascii.eqlIgnoreCase(option, "cert") or std.ascii.eqlIgnoreCase(option, "key")) {
            self.found_option = true;
            if (components.items.len > 1) return error.UnsupportedConfiguration;
            return;
        }
        if (!isKnownOpenVPNOption(option)) return;
        self.found_option = true;

        if (std.ascii.eqlIgnoreCase(option, "auth-user-pass")) {
            if (components.items.len > 1) return error.UnsupportedConfiguration;
            self.configuration.auth_user_pass = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "tls-auth")) {
            try self.putTLSDirective(.auth, components.items, line);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "tls-crypt")) {
            try self.putTLSDirective(.crypt, components.items, line);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "tls-crypt-v2")) {
            try self.putTLSDirective(.cryptV2, components.items, line);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "cipher")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.configuration.cipher = api.OpenVPNCipher.parseValue(allocator, .{ .string = components.items[1] }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnsupportedConfiguration,
            };
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "data-ciphers") or std.ascii.eqlIgnoreCase(option, "ncp-ciphers")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.data_ciphers.clearRetainingCapacity();
            var ciphers = std.mem.splitScalar(u8, components.items[1], ':');
            while (ciphers.next()) |cipher| {
                const parsed_cipher = api.OpenVPNCipher.parseValue(allocator, .{ .string = cipher }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.UnsupportedConfiguration,
                };
                try self.data_ciphers.append(allocator, parsed_cipher);
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "data-ciphers-fallback")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.configuration.cipher = api.OpenVPNCipher.parseValue(allocator, .{ .string = components.items[1] }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnsupportedConfiguration,
            };
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "auth")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.configuration.digest = api.OpenVPNDigest.parseValue(allocator, .{ .string = components.items[1] }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnsupportedConfiguration,
            };
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "comp-lzo")) {
            self.configuration.compression_framing = .compLZO;
            if (components.items.len > 1 and std.ascii.eqlIgnoreCase(components.items[1], "no")) {
                self.configuration.compression_algorithm = .disabled;
            } else {
                return error.UnsupportedCompression;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "compress")) {
            self.configuration.compression_framing = .compress;
            if (components.items.len == 1) {
                self.configuration.compression_algorithm = .disabled;
            } else if (std.ascii.eqlIgnoreCase(components.items[1], "stub")) {
                self.configuration.compression_algorithm = .disabled;
            } else if (std.ascii.eqlIgnoreCase(components.items[1], "stub-v2")) {
                self.configuration.compression_framing = .compressV2;
                self.configuration.compression_algorithm = .disabled;
            } else if (std.ascii.eqlIgnoreCase(components.items[1], "lzo")) {
                return error.UnsupportedCompression;
            } else {
                return error.UnsupportedCompression;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "key-direction")) {
            if (components.items.len == 2) {
                self.tls_key_direction = parseDirection(components.items[1]) orelse return error.MalformedOption;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "ping")) {
            if (components.items.len == 2) self.configuration.keep_alive_interval = std.fmt.parseFloat(f64, components.items[1]) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "ping-restart")) {
            if (components.items.len == 2) self.configuration.keep_alive_timeout = std.fmt.parseFloat(f64, components.items[1]) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "keepalive")) {
            if (components.items.len != 3) return error.MalformedOption;
            self.configuration.keep_alive_interval = std.fmt.parseFloat(f64, components.items[1]) catch return error.MalformedOption;
            self.configuration.keep_alive_timeout = std.fmt.parseFloat(f64, components.items[2]) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "reneg-sec")) {
            if (components.items.len == 2) self.configuration.renegotiates_after = std.fmt.parseFloat(f64, components.items[1]) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "proto")) {
            if (components.items.len != 2) return error.MalformedOption;
            self.default_protocol = parseIPSocketType(components.items[1]) orelse return error.UnsupportedConfiguration;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "port")) {
            if (components.items.len != 2) return error.MalformedOption;
            self.default_port = std.fmt.parseInt(u16, components.items[1], 10) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "remote")) {
            if (components.items.len < 2) return error.MalformedOption;
            const remote = RemoteBuilder{
                .address = try allocator.dupe(u8, components.items[1]),
                .port = if (components.items.len > 2)
                    std.fmt.parseInt(u16, components.items[2], 10) catch null
                else
                    null,
                .protocol = if (components.items.len > 3) parseIPSocketType(components.items[3]) else null,
            };
            errdefer {
                var mutable = remote;
                mutable.deinit(allocator);
            }
            try self.remotes.append(allocator, remote);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "remote-cert-tls")) {
            if (components.items.len > 1 and std.ascii.eqlIgnoreCase(components.items[1], "server")) {
                self.configuration.checks_eku = true;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "remote-random")) {
            self.configuration.randomize_endpoint = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "remote-random-hostname")) {
            self.configuration.randomize_hostnames = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "tun-mtu")) {
            if (components.items.len == 2) self.configuration.mtu = std.fmt.parseInt(i32, components.items[1], 10) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "static-challenge")) {
            self.configuration.static_challenge = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "auth-token")) {
            if (components.items.len == 2) util.replaceOwned(allocator, &self.configuration.auth_token, try allocator.dupe(u8, components.items[1]));
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "peer-id")) {
            if (components.items.len == 2) self.configuration.peer_id = std.fmt.parseInt(u32, components.items[1], 10) catch return error.MalformedOption;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "route")) {
            try self.putRoute4(allocator, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "route-ipv6")) {
            try self.putRoute6(allocator, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "route-gateway")) {
            if (components.items.len > 1) try replaceAddress(allocator, &self.configuration.route_gateway4, components.items[1]);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "route-ipv6-gateway")) {
            if (components.items.len > 1) try replaceAddress(allocator, &self.configuration.route_gateway6, components.items[1]);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "dhcp-option")) {
            try self.putDhcpOption(allocator, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "redirect-gateway")) {
            try self.putRedirectGateway(allocator, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "route-nopull")) {
            self.no_pull_mask.clearRetainingCapacity();
            try self.no_pull_mask.append(allocator, .routes);
            try self.no_pull_mask.append(allocator, .dns);
            try self.no_pull_mask.append(allocator, .proxy);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "scramble")) {
            try self.putScramble(allocator, components.items);
            return;
        }
    }

    fn putTLSDirective(
        self: *Builder,
        strategy: api.OpenVPNTLSWrapStrategy,
        components: []const []const u8,
        line: []const u8,
    ) ParseError!void {
        if (components.len > 1) {
            if (!std.ascii.eqlIgnoreCase(components[1], "inline") and !std.ascii.eqlIgnoreCase(components[1], "[inline]")) {
                _ = line;
                return error.UnsupportedConfiguration;
            }
            if (strategy == .auth and components.len > 2) {
                self.tls_key_direction = parseDirection(components[2]) orelse return error.MalformedOption;
            }
            if (strategy == .cryptV2 and components.len > 2) {
                if (!std.ascii.eqlIgnoreCase(components[2], "force-cookie") and !std.ascii.eqlIgnoreCase(components[2], "allow-noncookie")) {
                    return error.UnsupportedConfiguration;
                }
            }
        }
        self.tls_strategy = strategy;
    }

    fn finishBlock(
        self: *Builder,
        allocator: std.mem.Allocator,
        block_name: []const u8,
    ) ParseError!void {
        if (std.ascii.eqlIgnoreCase(block_name, "ca")) {
            replaceOpenVPNCryptoContainer(allocator, &self.configuration.ca, try std.mem.join(allocator, "\n", self.current_block_lines.items));
        } else if (std.ascii.eqlIgnoreCase(block_name, "cert")) {
            replaceOpenVPNCryptoContainer(allocator, &self.configuration.client_certificate, try std.mem.join(allocator, "\n", self.current_block_lines.items));
        } else if (std.ascii.eqlIgnoreCase(block_name, "key")) {
            try normalizeEncryptedPEMBlock(allocator, &self.current_block_lines);
            replaceOpenVPNCryptoContainer(allocator, &self.configuration.client_key, try std.mem.join(allocator, "\n", self.current_block_lines.items));
        } else if (std.ascii.eqlIgnoreCase(block_name, "tls-auth")) {
            try self.replaceTLSKeyLines(allocator);
            self.tls_strategy = .auth;
        } else if (std.ascii.eqlIgnoreCase(block_name, "tls-crypt")) {
            try self.replaceTLSKeyLines(allocator);
            self.tls_strategy = .crypt;
        } else if (std.ascii.eqlIgnoreCase(block_name, "tls-crypt-v2")) {
            try self.replaceTLSKeyLines(allocator);
            self.tls_strategy = .cryptV2;
        }

        for (self.current_block_lines.items) |item| allocator.free(item);
        self.current_block_lines.clearRetainingCapacity();
    }

    fn replaceTLSKeyLines(self: *Builder, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        if (self.tls_key_lines) |lines| util.freeSliceOfStrings(allocator, lines);
        self.tls_key_lines = try util.cloneSliceOfStrings(allocator, self.current_block_lines.items);
    }

    fn putRoute4(
        self: *Builder,
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) ParseError!void {
        if (components.len < 2) return;
        const mask = if (components.len > 2) components[2] else "255.255.255.255";
        const prefix = ipv4MaskPrefix(mask) orelse return error.MalformedOption;
        const destination = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ components[1], prefix });
        defer allocator.free(destination);
        var parsed_destination = (try api.Subnet.parseRawAlloc(allocator, destination)) orelse return error.MalformedOption;
        errdefer parsed_destination.deinit(allocator);
        var gateway = if (components.len > 3 and !std.ascii.eqlIgnoreCase(components[3], "vpn_gateway"))
            (try api.Address.parseRawAlloc(allocator, components[3])) orelse return error.MalformedOption
        else
            null;
        errdefer if (gateway) |*value| value.deinit(allocator);
        const route = api.Route{
            .destination = parsed_destination,
            .gateway = gateway,
        };
        try self.routes4.append(allocator, route);
    }

    fn putRoute6(
        self: *Builder,
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) ParseError!void {
        if (components.len < 2) return;
        if (std.mem.indexOfScalar(u8, components[1], '/') == null) return error.MalformedOption;
        var destination = (try api.Subnet.parseRawAlloc(allocator, components[1])) orelse return error.MalformedOption;
        errdefer destination.deinit(allocator);
        var gateway = if (components.len > 2 and !std.ascii.eqlIgnoreCase(components[2], "vpn_gateway"))
            (try api.Address.parseRawAlloc(allocator, components[2])) orelse return error.MalformedOption
        else
            null;
        errdefer if (gateway) |*value| value.deinit(allocator);
        const route = api.Route{
            .destination = destination,
            .gateway = gateway,
        };
        try self.routes6.append(allocator, route);
    }

    fn putDhcpOption(
        self: *Builder,
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) ParseError!void {
        if (components.len < 3) return;
        const key = components[1];
        if (std.ascii.eqlIgnoreCase(key, "DNS") or std.ascii.eqlIgnoreCase(key, "DNS6")) {
            try util.appendOwned(allocator, &self.dns_servers, components[2]);
        } else if (std.ascii.eqlIgnoreCase(key, "DOMAIN")) {
            util.replaceOwned(allocator, &self.configuration.dns_domain, try allocator.dupe(u8, components[2]));
        } else if (std.ascii.eqlIgnoreCase(key, "DOMAIN-SEARCH")) {
            try util.appendOwned(allocator, &self.search_domains, components[2]);
        } else if (std.ascii.eqlIgnoreCase(key, "PROXY_HTTP") or std.ascii.eqlIgnoreCase(key, "PROXY_HTTPS")) {
            if (components.len != 4) return error.MalformedOption;
            const endpoint = api.Endpoint{
                .address = try allocator.dupe(u8, components[2]),
                .port = std.fmt.parseInt(u16, components[3], 10) catch return error.MalformedOption,
                .owned = true,
            };
            if (std.ascii.eqlIgnoreCase(key, "PROXY_HTTP")) {
                if (self.configuration.http_proxy) |*old| old.deinit(allocator);
                self.configuration.http_proxy = endpoint;
            } else {
                if (self.configuration.https_proxy) |*old| old.deinit(allocator);
                self.configuration.https_proxy = endpoint;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "PROXY_AUTO_CONFIG_URL")) {
            util.replaceOwned(allocator, &self.configuration.proxy_auto_configuration_url, try allocator.dupe(u8, components[2]));
        } else if (std.ascii.eqlIgnoreCase(key, "PROXY_BYPASS")) {
            for (components[2..]) |domain| {
                try util.appendOwned(allocator, &self.proxy_bypass_domains, domain);
            }
        }
    }

    fn putRedirectGateway(
        self: *Builder,
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) error{OutOfMemory}!void {
        self.routing_policies.clearRetainingCapacity();
        try self.routing_policies.append(allocator, .IPv4);
        for (components[1..]) |option| {
            if (std.ascii.eqlIgnoreCase(option, "!ipv4")) {
                removeRoutingPolicy(&self.routing_policies, .IPv4);
            } else if (std.ascii.eqlIgnoreCase(option, "ipv6")) {
                try appendRoutingPolicyIfMissing(allocator, &self.routing_policies, .IPv6);
            } else if (std.ascii.eqlIgnoreCase(option, "block-local")) {
                try appendRoutingPolicyIfMissing(allocator, &self.routing_policies, .blockLocal);
            }
        }
    }

    fn putScramble(
        self: *Builder,
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) ParseError!void {
        if (components.len < 2) return;
        if (self.configuration.xor_method) |*old| old.deinit(allocator);
        self.configuration.xor_method = null;
        if (std.ascii.eqlIgnoreCase(components[1], "xormask")) {
            if (components.len > 2) self.configuration.xor_method = .{ .xormask = .{
                .mask = try api.SecureData.initBytesAlloc(allocator, components[2]),
            } };
        } else if (std.ascii.eqlIgnoreCase(components[1], "xorptrpos")) {
            self.configuration.xor_method = .{ .xorptrpos = .{} };
        } else if (std.ascii.eqlIgnoreCase(components[1], "reverse")) {
            self.configuration.xor_method = .{ .reverse = .{} };
        } else if (std.ascii.eqlIgnoreCase(components[1], "obfuscate")) {
            if (components.len > 2) self.configuration.xor_method = .{ .obfuscate = .{
                .mask = try api.SecureData.initBytesAlloc(allocator, components[2]),
            } };
        }
    }

    fn build(self: *Builder, allocator: std.mem.Allocator) ParseError!api.OpenVPNConfiguration {
        if (!self.found_option) return error.InvalidFormat;

        if (self.data_ciphers.items.len > 0) {
            self.configuration.data_ciphers = try self.data_ciphers.toOwnedSlice(allocator);
        }

        if (self.remotes.items.len > 0) {
            const remotes = try allocator.alloc(api.ExtendedEndpoint, self.remotes.items.len);
            var initialized: usize = 0;
            errdefer {
                for (remotes[0..initialized]) |*remote| remote.deinit(allocator);
                allocator.free(remotes);
            }
            for (self.remotes.items, 0..) |remote, index| {
                remotes[index] = .{
                    .address = try allocator.dupe(u8, remote.address),
                    .proto = .{
                        .socket_type = remote.protocol orelse self.default_protocol,
                        .port = remote.port orelse self.default_port,
                    },
                    .owned = true,
                };
                initialized += 1;
            }
            self.configuration.remotes = remotes;
        }

        if (self.routes4.items.len > 0) self.configuration.routes4 = try self.routes4.toOwnedSlice(allocator);
        if (self.routes6.items.len > 0) self.configuration.routes6 = try self.routes6.toOwnedSlice(allocator);
        if (self.dns_servers.items.len > 0) self.configuration.dns_servers = try self.dns_servers.toOwnedSlice(allocator);
        if (self.search_domains.items.len > 0) self.configuration.search_domains = try self.search_domains.toOwnedSlice(allocator);
        if (self.proxy_bypass_domains.items.len > 0) self.configuration.proxy_bypass_domains = try self.proxy_bypass_domains.toOwnedSlice(allocator);
        if (self.routing_policies.items.len > 0) self.configuration.routing_policies = try self.routing_policies.toOwnedSlice(allocator);
        if (self.no_pull_mask.items.len > 0) self.configuration.no_pull_mask = try self.no_pull_mask.toOwnedSlice(allocator);

        if (self.tls_strategy) |strategy| {
            const lines = self.tls_key_lines orelse {
                const name = tlsStrategyOptionName(strategy);
                self.context.setParseErrorInfo(allocator, name, name);
                return error.MalformedOption;
            };
            self.configuration.tls_wrap = switch (strategy) {
                .auth => .{
                    .strategy = .auth,
                    .key = .{
                        .data = try parseStaticKeyData(allocator, lines),
                        .dir = self.tls_key_direction,
                    },
                },
                .crypt => .{
                    .strategy = .crypt,
                    .key = .{
                        .data = try parseStaticKeyData(allocator, lines),
                        .dir = .client,
                    },
                },
                .cryptV2 => try parseCryptV2Key(allocator, lines),
            };
        }

        try self.decryptClientKeyIfNeeded(allocator);

        const result = self.configuration;
        self.configuration = .{};
        self.data_ciphers = .empty;
        self.routes4 = .empty;
        self.routes6 = .empty;
        self.dns_servers = .empty;
        self.search_domains = .empty;
        self.proxy_bypass_domains = .empty;
        self.routing_policies = .empty;
        self.no_pull_mask = .empty;
        return result;
    }

    fn decryptClientKeyIfNeeded(self: *Builder, allocator: std.mem.Allocator) ParseError!void {
        const client_key = self.configuration.client_key orelse return;
        if (!client_key.isEncrypted()) return;

        const passphrase = self.context.passphrase orelse return error.EmptyPassphrase;
        if (passphrase.len == 0) return error.EmptyPassphrase;

        const decrypt_key = self.decrypt_key orelse return error.DecrypterRequired;
        const decrypted_pem = decrypt_key(self.decrypt_key_ctx, allocator, client_key.pem, passphrase) catch return error.UnableToDecrypt;
        replaceOpenVPNCryptoContainer(allocator, &self.configuration.client_key, decrypted_pem);
    }
};

const RemoteBuilder = struct {
    address: []u8,
    port: ?u16 = null,
    protocol: ?api.IPSocketType = null,

    fn deinit(self: *RemoteBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};

fn blockBeginName(line: []const u8) ?[]const u8 {
    if (line.len < 3 or line[0] != '<' or line[1] == '/') return null;
    if (line[line.len - 1] != '>') return null;
    return line[1 .. line.len - 1];
}

fn blockEndName(line: []const u8) ?[]const u8 {
    if (line.len < 4 or line[0] != '<' or line[1] != '/') return null;
    if (line[line.len - 1] != '>') return null;
    return line[2 .. line.len - 1];
}

fn parseDirection(value: []const u8) ?api.OpenVPNStaticKeyDirection {
    const raw = std.fmt.parseInt(u8, value, 10) catch return null;
    return switch (raw) {
        0 => .server,
        1 => .client,
        else => null,
    };
}

fn parseIPSocketType(value: []const u8) ?api.IPSocketType {
    if (std.ascii.eqlIgnoreCase(value, "udp")) return .udp;
    if (std.ascii.eqlIgnoreCase(value, "udp4")) return .udp4;
    if (std.ascii.eqlIgnoreCase(value, "udp6")) return .udp6;
    if (std.ascii.eqlIgnoreCase(value, "tcp")) return .tcp;
    if (std.ascii.eqlIgnoreCase(value, "tcp4")) return .tcp4;
    if (std.ascii.eqlIgnoreCase(value, "tcp6")) return .tcp6;
    return null;
}

fn lineOptionName(line: []const u8) []const u8 {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    return words.next() orelse line;
}

fn tlsStrategyOptionName(strategy: api.OpenVPNTLSWrapStrategy) []const u8 {
    return switch (strategy) {
        .auth => "tls-auth",
        .crypt => "tls-crypt",
        .cryptV2 => "tls-crypt-v2",
    };
}

fn ipv4MaskPrefix(mask: []const u8) ?u8 {
    var prefix: u8 = 0;
    var octets = std.mem.splitScalar(u8, mask, '.');
    var octet_count: u8 = 0;
    var saw_zero = false;
    while (octets.next()) |octet_text| {
        const octet = std.fmt.parseInt(u8, octet_text, 10) catch return null;
        octet_count += 1;
        for (0..8) |bit| {
            const shift: u3 = @intCast(bit);
            const mask_bit = @as(u8, 0x80) >> shift;
            if ((octet & mask_bit) != 0) {
                if (saw_zero) return null;
                prefix += 1;
            } else {
                saw_zero = true;
            }
        }
    }
    if (octet_count != 4) return null;
    return prefix;
}

fn parseStaticKeyData(allocator: std.mem.Allocator, lines: []const []u8) ParseError!api.SecureData {
    const hex = try parseStaticKeyHex(allocator, lines);
    defer allocator.free(hex);
    return (try api.SecureData.parseHexAlloc(allocator, hex)) orelse error.MalformedOption;
}

fn parseStaticKeyHex(allocator: std.mem.Allocator, lines: []const []u8) ParseError![]u8 {
    var hex: std.ArrayList(u8) = .empty;
    defer hex.deinit(allocator);

    var in_key = false;
    for (lines) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.ascii.eqlIgnoreCase(line, "-----BEGIN OpenVPN Static key V1-----")) {
            in_key = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(line, "-----END OpenVPN Static key V1-----")) {
            break;
        }
        if (!in_key) continue;
        if (!util.containsOnly(line, "0123456789abcdefABCDEF")) return error.MalformedOption;
        try hex.appendSlice(allocator, line);
    }
    if (hex.items.len != 512) return error.MalformedOption;
    return try hex.toOwnedSlice(allocator);
}

fn parseCryptV2Key(allocator: std.mem.Allocator, lines: []const []u8) ParseError!api.OpenVPNTLSWrap {
    var base64: std.ArrayList(u8) = .empty;
    defer base64.deinit(allocator);
    var in_key = false;
    for (lines) |line| {
        if (line.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(line, "-----BEGIN OpenVPN tls-crypt-v2 client key-----")) {
            in_key = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(line, "-----END OpenVPN tls-crypt-v2 client key-----")) {
            break;
        }
        if (in_key) try base64.appendSlice(allocator, line);
    }

    var encoded = (try api.SecureData.parseRawAlloc(allocator, base64.items)) orelse return error.MalformedOption;
    defer encoded.deinit(allocator);
    const decoded = encoded.bytesAlloc(allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedOption,
    };
    defer allocator.free(decoded);
    if (decoded.len <= 256) return error.MalformedOption;

    var static_key = try api.SecureData.initBytesAlloc(allocator, decoded[0..256]);
    errdefer static_key.deinit(allocator);
    var wrapped_key = try api.SecureData.initBytesAlloc(allocator, decoded[256..]);
    errdefer wrapped_key.deinit(allocator);

    return .{
        .strategy = .cryptV2,
        .key = .{
            .data = static_key,
            .dir = .client,
        },
        .wrapped_key = wrapped_key,
    };
}

fn normalizeEncryptedPEMBlock(
    allocator: std.mem.Allocator,
    block: *std.ArrayList([]u8),
) error{OutOfMemory}!void {
    if (block.items.len >= 3 and std.mem.indexOf(u8, block.items[1], "Proc-Type") != null) {
        const blank = try allocator.dupe(u8, "");
        errdefer allocator.free(blank);
        try block.insert(allocator, 3, blank);
    }
}

fn appendRoutingPolicyIfMissing(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(api.OpenVPNRoutingPolicy),
    policy: api.OpenVPNRoutingPolicy,
) error{OutOfMemory}!void {
    for (list.items) |item| {
        if (item == policy) return;
    }
    try list.append(allocator, policy);
}

fn removeRoutingPolicy(list: *std.ArrayList(api.OpenVPNRoutingPolicy), policy: api.OpenVPNRoutingPolicy) void {
    var index: usize = 0;
    while (index < list.items.len) {
        if (list.items[index] == policy) {
            _ = list.orderedRemove(index);
            return;
        }
        index += 1;
    }
}

fn replaceAddress(
    allocator: std.mem.Allocator,
    field: *?api.Address,
    raw: []const u8,
) ParseError!void {
    const value = (try api.Address.parseRawAlloc(allocator, raw)) orelse return error.MalformedOption;
    if (field.*) |*old| old.deinit(allocator);
    field.* = value;
}

fn replaceOpenVPNCryptoContainer(
    allocator: std.mem.Allocator,
    field: *?api.OpenVPNCryptoContainer,
    pem: []u8,
) void {
    if (field.*) |*old| old.deinit(allocator);
    field.* = .{
        .pem = pem,
        .owned = true,
    };
}

fn importParserContext(context: ?core.ImportContext) Parser.Context {
    const import_context = context orelse return .{};
    var parser_context = if (import_context.cast(Parser.Context, .OpenVPN)) |value| value.* else Parser.Context{};
    if (import_context.parse_error_info) |info| {
        parser_context.parse_error_info = info;
    }
    return parser_context;
}

fn setRecognizedType(context: ?core.ImportContext) void {
    const import_context = context orelse return;
    import_context.setRecognizedType(.OpenVPN);
}

const known_openvpn_options = [_][]const u8{
    "auth",
    "auth-nocache",
    "auth-token",
    "auth-user-pass",
    "cipher",
    "client",
    "comp-lzo",
    "compress",
    "data-ciphers",
    "data-ciphers-fallback",
    "dev",
    "dhcp-option",
    "explicit-exit-notify",
    "fast-io",
    "float",
    "keepalive",
    "key-direction",
    "mute-replay-warnings",
    "ncp-ciphers",
    "nobind",
    "persist-key",
    "persist-tun",
    "peer-id",
    "ping",
    "ping-restart",
    "port",
    "proto",
    "pull",
    "redirect-gateway",
    "remote",
    "remote-cert-eku",
    "remote-cert-ku",
    "remote-cert-tls",
    "remote-random",
    "remote-random-hostname",
    "reneg-sec",
    "resolv-retry",
    "route",
    "route-gateway",
    "route-ipv6",
    "route-ipv6-gateway",
    "route-nopull",
    "scramble",
    "static-challenge",
    "tls-auth",
    "tls-client",
    "tls-crypt",
    "tls-crypt-v2",
    "topology",
    "tun-mtu",
    "verb",
    "verify-x509-name",
};

fn isKnownOpenVPNOption(option: []const u8) bool {
    for (known_openvpn_options) |known_option| {
        if (std.ascii.eqlIgnoreCase(option, known_option)) return true;
    }
    return false;
}
