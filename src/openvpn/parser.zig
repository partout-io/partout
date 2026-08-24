// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const c_mod = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const keys_mod = @import("internal/keys.zig");

const api = core.api;
const c_common = c_mod.common;
const CryptoBackend = c_mod.CryptoBackend;
const StaticKey = keys_mod.StaticKey;
const util = core.util;

pub fn importModule(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    contents: []const u8,
    context: ?core.ImportContext,
) core.ImportError!api.TaggedModule {
    const parser = if (c_mod.has_default_crypto_backend)
        Parser.init(null)
    else
        Parser{};
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
    if (!isCompleteClientConfiguration(&configuration)) {
        configuration.deinit(allocator);
        return error.Parsing;
    }
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
    pub const DecryptError = std.mem.Allocator.Error || error{
        DecryptionFailed,
    };

    pub const DecryptKey = *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
        []const u8,
    ) DecryptError![]u8;

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

    pub fn init(backend: ?CryptoBackend) Parser {
        return .{
            .decrypt_key = decryptKey(backend orelse CryptoBackend.default()),
        };
    }

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
        var builder = Builder.init(
            context,
            self.decrypt_key_ctx,
            self.decrypt_key,
        );
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

fn decryptKey(backend: CryptoBackend) Parser.DecryptKey {
    return switch (backend) {
        .openssl => decryptKeyWithBackend(.openssl),
        .mbedtls => decryptKeyWithBackend(.mbedtls),
        .native => decryptKeyWithBackend(.native),
        .mock => decryptKeyWithBackend(.mock),
    };
}

fn decryptKeyWithBackend(comptime backend: CryptoBackend) Parser.DecryptKey {
    return struct {
        fn decrypt(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            pem: []const u8,
            passphrase: []const u8,
        ) Parser.DecryptError![]u8 {
            var c_pem: util.TemporaryCString = .{};
            try c_pem.init(allocator, pem);
            defer {
                @memset(@constCast(c_pem.slice()), 0);
                c_pem.deinit();
            }

            var c_passphrase: util.TemporaryCString = .{};
            try c_passphrase.init(allocator, passphrase);
            defer {
                @memset(@constCast(c_passphrase.slice()), 0);
                c_passphrase.deinit();
            }

            const function_table = c_mod.cryptoFunctionTable(backend) catch
                return error.DecryptionFailed;
            const decrypt_function = function_table.key_decrypted_from_pem orelse
                @panic("OpenVPN crypto backend does not define key_decrypted_from_pem");
            const c_decrypted = decrypt_function(c_pem.ptr(), c_passphrase.ptr()) orelse
                return error.DecryptionFailed;
            const decrypted = std.mem.span(@as([*:0]u8, @ptrCast(c_decrypted)));
            defer {
                c_common.pp_zero(c_decrypted, decrypted.len);
                c_common.pp_free(c_decrypted);
            }
            return try allocator.dupe(u8, decrypted);
        }
    }.decrypt;
}

const Builder = struct {
    configuration: api.OpenVPNConfiguration,
    legacy_cipher: ?api.OpenVPNCipher,
    data_ciphers_fallback: ?api.OpenVPNCipher,
    data_ciphers: std.ArrayList(api.OpenVPNCipher),
    remotes: std.ArrayList(RemoteBuilder),
    routes4: std.ArrayList(api.Route),
    routes6: std.ArrayList(api.Route),
    dns_servers: std.ArrayList([]u8),
    search_domains: std.ArrayList([]u8),
    proxy_bypass_domains: std.ArrayList([]u8),
    routing_policies: std.ArrayList(api.OpenVPNRoutingPolicy),
    no_pull_mask: std.ArrayList(api.OpenVPNPullMask),
    current_block_name: ?[]const u8,
    current_block_lines: std.ArrayList([]const u8),
    tls_strategy: ?api.OpenVPNTLSWrapStrategy,
    tls_key_lines: ?[][]const u8,
    tls_key_direction: ?api.OpenVPNStaticKeyDirection,
    default_protocol: api.IPSocketType,
    default_port: u16,
    topology: Topology,
    ifconfig4: ?IfconfigArguments,
    ifconfig6: ?IfconfigArguments,
    route_gateway4_argument_count: ?usize,
    found_option: bool,
    context: Parser.Context,
    decrypt_key_ctx: ?*anyopaque,
    decrypt_key: ?Parser.DecryptKey,

    fn init(
        context: Parser.Context,
        decrypt_key_ctx: ?*anyopaque,
        decrypt_key: ?Parser.DecryptKey,
    ) Builder {
        return .{
            .configuration = .{},
            .legacy_cipher = null,
            .data_ciphers_fallback = null,
            .data_ciphers = .empty,
            .remotes = .empty,
            .routes4 = .empty,
            .routes6 = .empty,
            .dns_servers = .empty,
            .search_domains = .empty,
            .proxy_bypass_domains = .empty,
            .routing_policies = .empty,
            .no_pull_mask = .empty,
            .current_block_name = null,
            .current_block_lines = .empty,
            .tls_strategy = null,
            .tls_key_lines = null,
            .tls_key_direction = null,
            .default_protocol = .udp,
            .default_port = 1194,
            .topology = .net30,
            .ifconfig4 = null,
            .ifconfig6 = null,
            .route_gateway4_argument_count = null,
            .found_option = false,
            .context = context,
            .decrypt_key_ctx = decrypt_key_ctx,
            .decrypt_key = decrypt_key,
        };
    }

    fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.configuration.deinit(allocator);
        self.data_ciphers.deinit(allocator);
        self.remotes.deinit(allocator);
        util.deinitList(api.Route, allocator, &self.routes4);
        util.deinitList(api.Route, allocator, &self.routes6);
        util.deinitListOfStrings(allocator, &self.dns_servers);
        util.deinitListOfStrings(allocator, &self.search_domains);
        util.deinitListOfStrings(allocator, &self.proxy_bypass_domains);
        self.routing_policies.deinit(allocator);
        self.no_pull_mask.deinit(allocator);
        self.current_block_lines.deinit(allocator);
        if (self.tls_key_lines) |lines| allocator.free(lines);
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
                    self.current_block_name = null;
                    return;
                }
            }
            try self.current_block_lines.append(allocator, line);
            return;
        }

        if (blockBeginName(line)) |name| {
            if (std.ascii.eqlIgnoreCase(name, "connection") or
                std.ascii.eqlIgnoreCase(name, "auth-user-pass"))
            {
                self.context.setParseErrorInfo(allocator, name, line);
                return error.UnsupportedConfiguration;
            }
            self.current_block_name = name;
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
            try self.putTLSDirective(.auth, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "tls-crypt")) {
            try self.putTLSDirective(.crypt, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "tls-crypt-v2")) {
            try self.putTLSDirective(.cryptV2, components.items);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "cipher")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.legacy_cipher = util.parseRawIgnoreCase(api.OpenVPNCipher, components.items[1]);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "data-ciphers") or std.ascii.eqlIgnoreCase(option, "ncp-ciphers")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.data_ciphers.clearRetainingCapacity();
            var ciphers = std.mem.splitScalar(u8, components.items[1], ':');
            while (ciphers.next()) |cipher| {
                const is_optional = std.mem.startsWith(u8, cipher, "?");
                const name = if (is_optional) cipher[1..] else cipher;
                const parsed_cipher = util.parseRawIgnoreCase(api.OpenVPNCipher, name) orelse continue;
                try self.data_ciphers.append(allocator, parsed_cipher);
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "data-ciphers-fallback")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.data_ciphers_fallback = util.parseRawIgnoreCase(api.OpenVPNCipher, components.items[1]);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "auth")) {
            if (components.items.len < 2) return error.MalformedOption;
            self.configuration.digest = util.parseRawIgnoreCase(api.OpenVPNDigest, components.items[1]) orelse return error.UnsupportedConfiguration;
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
            if (components.items.len != 2) {
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
                self.tls_key_direction = parseDirection(components.items[1]);
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
            if (std.fmt.parseInt(u16, components.items[1], 10) catch null) |port|
                self.default_port = port;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "remote")) {
            if (components.items.len < 2) return error.MalformedOption;
            const remote = RemoteBuilder{
                .address = components.items[1],
                .port = if (components.items.len > 2)
                    std.fmt.parseInt(u16, components.items[2], 10) catch null
                else
                    null,
                .protocol = if (components.items.len > 3) parseIPSocketType(components.items[3]) else null,
            };
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
            if (components.items.len == 2) self.configuration.mtu = std.fmt.parseInt(i32, components.items[1], 10) catch null;
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
            if (components.items.len == 2) self.configuration.peer_id = std.fmt.parseInt(u32, components.items[1], 10) catch null;
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "topology")) {
            if (components.items.len != 2) return;
            if (Topology.parse(components.items[1])) |topology| {
                self.topology = topology;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "ifconfig")) {
            if (components.items.len < 3) return;
            self.ifconfig4 = IfconfigArguments.init(components.items[1..]);
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "ifconfig-ipv6")) {
            if (components.items.len < 3) return;
            self.ifconfig6 = IfconfigArguments.init(components.items[1..]);
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
            if (components.items.len > 1) {
                replaceAddress(allocator, &self.configuration.route_gateway4, components.items[1]) catch |err| switch (err) {
                    error.MalformedOption => return,
                    else => return err,
                };
                self.route_gateway4_argument_count = 1;
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(option, "route-ipv6-gateway")) {
            if (components.items.len > 1) {
                replaceAddress(allocator, &self.configuration.route_gateway6, components.items[1]) catch |err| switch (err) {
                    error.MalformedOption => return,
                    else => return err,
                };
            }
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
    ) ParseError!void {
        if (components.len > 1) {
            if (!std.ascii.eqlIgnoreCase(components[1], "inline") and !std.ascii.eqlIgnoreCase(components[1], "[inline]")) {
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

        self.current_block_lines.clearRetainingCapacity();
    }

    fn replaceTLSKeyLines(self: *Builder, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const new_lines = try allocator.dupe([]const u8, self.current_block_lines.items);
        if (self.tls_key_lines) |lines| allocator.free(lines);
        self.tls_key_lines = new_lines;
    }

    fn putRoute4(
        self: *Builder,
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) ParseError!void {
        if (components.len < 2) return;
        if (components.len > 3 and
            std.ascii.eqlIgnoreCase(components[1], "remote_host") and
            std.ascii.eqlIgnoreCase(components[3], "net_gateway")) return;
        const mask = if (components.len > 2) components[2] else "255.255.255.255";
        const prefix = ipv4MaskPrefix(mask) orelse return error.MalformedOption;
        const destination = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ components[1], prefix });
        defer allocator.free(destination);
        var parsed_destination = (try api.Subnet.parseRawAlloc(allocator, destination)) orelse return error.MalformedOption;
        errdefer parsed_destination.deinit(allocator);
        var gateway = if (components.len > 3 and !std.ascii.eqlIgnoreCase(components[3], "vpn_gateway"))
            try api.Address.parseRawAlloc(allocator, components[3])
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
            try api.Address.parseRawAlloc(allocator, components[2])
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
            const port = std.fmt.parseInt(u16, components[3], 10) catch return;
            const endpoint = api.Endpoint{
                .address = try allocator.dupe(u8, components[2]),
                .port = port,
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

        // The explicit compatibility fallback is distinct from deprecated
        // `cipher` input and takes precedence regardless of directive order.
        self.configuration.cipher = self.data_ciphers_fallback orelse self.legacy_cipher;
        try self.buildRoutingSettings(allocator);
        self.configuration.data_ciphers = try takeOwnedSliceOrNull(allocator, &self.data_ciphers);

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

        self.configuration.routes4 = try takeOwnedSliceOrNull(allocator, &self.routes4);
        self.configuration.routes6 = try takeOwnedSliceOrNull(allocator, &self.routes6);
        self.configuration.dns_servers = try takeOwnedSliceOrNull(allocator, &self.dns_servers);
        self.configuration.search_domains = try takeOwnedSliceOrNull(allocator, &self.search_domains);
        self.configuration.proxy_bypass_domains = try takeOwnedSliceOrNull(allocator, &self.proxy_bypass_domains);
        self.configuration.routing_policies = try takeOwnedSliceOrNull(allocator, &self.routing_policies);
        self.configuration.no_pull_mask = try takeOwnedSliceOrNull(allocator, &self.no_pull_mask);

        if (self.tls_strategy) |strategy| {
            const lines = self.tls_key_lines orelse {
                const name = tlsStrategyOptionName(strategy);
                self.context.setParseErrorInfo(allocator, name, name);
                return error.MalformedOption;
            };
            self.configuration.tls_wrap = switch (strategy) {
                .auth => .{
                    .strategy = .auth,
                    .key = StaticKey.parseFileAlloc(
                        allocator,
                        lines,
                        self.tls_key_direction,
                    ) catch |err| return mapStaticKeyParseError(err),
                },
                .crypt => .{
                    .strategy = .crypt,
                    .key = StaticKey.parseFileAlloc(allocator, lines, .client) catch |err|
                        return mapStaticKeyParseError(err),
                },
                .cryptV2 => StaticKey.parseCryptV2FileAlloc(allocator, lines) catch |err|
                    return mapStaticKeyParseError(err),
            };
        }

        try self.decryptClientKeyIfNeeded(allocator);

        const result = self.configuration;
        self.configuration = .{};
        return result;
    }

    fn buildRoutingSettings(
        self: *Builder,
        allocator: std.mem.Allocator,
    ) ParseError!void {
        if (self.ifconfig4) |arguments| {
            if (arguments.count != 2) {
                self.context.setParseErrorInfo(
                    allocator,
                    "ifconfig",
                    "ifconfig takes 2 arguments",
                );
                return error.MalformedOption;
            }

            const address = arguments.first.?;
            const remote_or_mask = arguments.second.?;
            switch (self.topology) {
                .subnet => {
                    if (self.route_gateway4_argument_count != 1) {
                        self.context.setParseErrorInfo(
                            allocator,
                            "route-gateway",
                            "route-gateway takes 1 argument",
                        );
                        return error.MalformedOption;
                    }
                    const prefix = ipv4MaskPrefix(remote_or_mask) orelse
                        return error.MalformedOption;
                    self.configuration.ipv4 = try ipSettings(
                        allocator,
                        address,
                        prefix,
                        .v4,
                    );
                    const gateway = self.configuration.route_gateway4 orelse
                        return error.MalformedOption;
                    if (gateway.family != .v4) return error.MalformedOption;
                },
                .net30 => {
                    self.configuration.ipv4 = try ipSettings(
                        allocator,
                        address,
                        30,
                        .v4,
                    );
                    try replaceIPAddress(
                        allocator,
                        &self.configuration.route_gateway4,
                        remote_or_mask,
                        .v4,
                    );
                },
                .p2p => {
                    self.context.setParseErrorInfo(
                        allocator,
                        "topology",
                        "topology p2p",
                    );
                    return error.UnsupportedConfiguration;
                },
            }
        }

        if (self.ifconfig6) |arguments| {
            if (arguments.count != 2) {
                self.context.setParseErrorInfo(
                    allocator,
                    "ifconfig-ipv6",
                    "ifconfig-ipv6 takes 2 arguments",
                );
                return error.MalformedOption;
            }
            const raw_subnet = arguments.first.?;
            const parsed = api.Subnet.parseRaw(raw_subnet) orelse
                return error.MalformedOption;
            if (parsed.address.family != .v6) return error.MalformedOption;
            self.configuration.ipv6 = try ipSettings(
                allocator,
                parsed.address.raw,
                parsed.prefix_length,
                .v6,
            );
            try replaceIPAddress(
                allocator,
                &self.configuration.route_gateway6,
                arguments.second.?,
                .v6,
            );
        }
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
    address: []const u8,
    port: ?u16 = null,
    protocol: ?api.IPSocketType = null,
};

const Topology = enum {
    net30,
    p2p,
    subnet,

    fn parse(raw: []const u8) ?Topology {
        if (std.ascii.eqlIgnoreCase(raw, "net30")) return .net30;
        if (std.ascii.eqlIgnoreCase(raw, "p2p")) return .p2p;
        if (std.ascii.eqlIgnoreCase(raw, "subnet")) return .subnet;
        return null;
    }
};

const IfconfigArguments = struct {
    first: ?[]const u8 = null,
    second: ?[]const u8 = null,
    count: usize,

    fn init(arguments: []const []const u8) IfconfigArguments {
        return .{
            .first = if (arguments.len > 0) arguments[0] else null,
            .second = if (arguments.len > 1) arguments[1] else null,
            .count = arguments.len,
        };
    }
};

fn takeOwnedSliceOrNull(
    allocator: std.mem.Allocator,
    list: anytype,
) error{OutOfMemory}!?@TypeOf(list.items) {
    if (list.items.len == 0) return null;
    return try list.toOwnedSlice(allocator);
}

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
    const raw = std.fmt.parseInt(i32, value, 10) catch return null;
    return api.OpenVPNStaticKeyDirection.parseFromRaw(raw);
}

fn parseIPSocketType(value: []const u8) ?api.IPSocketType {
    if (std.ascii.eqlIgnoreCase(value, "tcp-client")) return .tcp;
    if (std.ascii.eqlIgnoreCase(value, "tcp4-client")) return .tcp4;
    if (std.ascii.eqlIgnoreCase(value, "tcp6-client")) return .tcp6;

    inline for (std.meta.fields(api.IPSocketType)) |field| {
        const socket_type: api.IPSocketType = @field(api.IPSocketType, field.name);
        if (std.ascii.eqlIgnoreCase(value, socket_type.raw())) return socket_type;
    }
    return null;
}

fn isCompleteClientConfiguration(configuration: *const api.OpenVPNConfiguration) bool {
    if (configuration.ca == null) return false;
    const remotes = configuration.remotes orelse return false;
    return remotes.len > 0;
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

fn mapStaticKeyParseError(err: StaticKey.ParseError) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidStaticKey => error.MalformedOption,
    };
}

fn normalizeEncryptedPEMBlock(
    allocator: std.mem.Allocator,
    block: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    if (block.items.len >= 3 and std.mem.indexOf(u8, block.items[1], "Proc-Type") != null) {
        try block.insert(allocator, 3, "");
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

fn replaceIPAddress(
    allocator: std.mem.Allocator,
    field: *?api.Address,
    raw: []const u8,
    family: api.Address.Family,
) ParseError!void {
    var value = (try api.Address.parseRawAlloc(allocator, raw)) orelse
        return error.MalformedOption;
    errdefer value.deinit(allocator);
    if (value.family != family) return error.MalformedOption;
    if (field.*) |*old| old.deinit(allocator);
    field.* = value;
}

fn ipSettings(
    allocator: std.mem.Allocator,
    address: []const u8,
    prefix: u8,
    family: api.Address.Family,
) ParseError!api.IPSettings {
    const raw_subnet = try std.fmt.allocPrint(
        allocator,
        "{s}/{d}",
        .{ address, prefix },
    );
    defer allocator.free(raw_subnet);

    var subnet = (try api.Subnet.parseRawAlloc(allocator, raw_subnet)) orelse
        return error.MalformedOption;
    errdefer subnet.deinit(allocator);
    if (subnet.address.family != family) return error.MalformedOption;

    const raw_network = subnet.networkRawAlloc(allocator) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidModel, error.Stringify => error.MalformedOption,
        };
    };
    defer allocator.free(raw_network);
    var network = (try api.Subnet.parseRawAlloc(allocator, raw_network)) orelse
        return error.MalformedOption;
    errdefer network.deinit(allocator);

    const subnets = try allocator.alloc(api.Subnet, 1);
    errdefer allocator.free(subnets);
    subnets[0] = subnet;

    const routes = try allocator.alloc(api.Route, 1);
    errdefer allocator.free(routes);
    routes[0] = .{ .destination = network };

    return .{
        .subnets = subnets,
        .included_routes = routes,
    };
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
    "ifconfig",
    "ifconfig-ipv6",
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
