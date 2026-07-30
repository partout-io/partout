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
            error.InvalidLine => error.UnknownImportedModule,
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
    const module = api.TaggedModule{ .WireGuard = .{
        .id = module_id,
        .configuration = configuration,
    } };
    return module;
}

pub const Parser = struct {
    pub const Context = struct {
        parse_error_info: ?*api.ParseErrorInfo = null,

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

    pub fn parse(
        allocator: std.mem.Allocator,
        contents: []const u8,
    ) ParseError!api.WireGuardConfiguration {
        return (Parser{}).parseWithContext(allocator, contents, .{});
    }

    pub fn parseWithContext(
        _: Parser,
        allocator: std.mem.Allocator,
        contents: []const u8,
        context: Context,
    ) ParseError!api.WireGuardConfiguration {
        var section: Section = .none;
        var interface_builder = InterfaceBuilder{};
        defer interface_builder.deinit(allocator);
        var has_interface = false;

        var peer_builder: ?PeerBuilder = null;
        defer if (peer_builder) |*builder| builder.deinit(allocator);

        var peers: std.ArrayList(api.WireGuardRemoteInterface) = .empty;
        defer util.deinitList(api.WireGuardRemoteInterface, allocator, &peers);

        var error_name: []const u8 = "";
        var error_line: []const u8 = "";
        errdefer context.setParseErrorInfo(allocator, error_name, error_line);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const uncommented = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
                raw_line[0..index]
            else
                raw_line;
            const line = util.trim(uncommented);
            if (line.len == 0) continue;

            error_name = "";
            error_line = line;

            if (std.ascii.eqlIgnoreCase(line, "[interface]")) {
                if (section == .peer) {
                    try appendBuiltPeer(allocator, &peers, &peer_builder);
                } else if (section == .interface) {
                    return error.MultipleInterfaces;
                }
                if (has_interface) return error.MultipleInterfaces;
                section = .interface;
                has_interface = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, "[peer]")) {
                if (section == .peer) try appendBuiltPeer(allocator, &peers, &peer_builder);
                if (section == .none) return error.NoInterface;
                section = .peer;
                peer_builder = PeerBuilder{};
                continue;
            }

            const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
            const key = util.trim(line[0..separator]);
            error_name = key;
            if (key.len > 64) return error.InvalidLine;
            const value = util.trim(line[separator + 1 ..]);

            switch (section) {
                .none => return error.InvalidLine,
                .interface => try interface_builder.put(allocator, key, value),
                .peer => try peer_builder.?.put(allocator, key, value),
            }
        }

        if (section == .peer) try appendBuiltPeer(allocator, &peers, &peer_builder);
        if (!has_interface) return error.NoInterface;

        var interface = try interface_builder.build(allocator);
        errdefer interface.deinit(allocator);

        try ensureUniquePeerPublicKeys(peers.items);
        const owned_peers = try peers.toOwnedSlice(allocator);
        return .{
            .interface = interface,
            .peers = owned_peers,
        };
    }

    fn appendBuiltPeer(
        allocator: std.mem.Allocator,
        peers: *std.ArrayList(api.WireGuardRemoteInterface),
        peer_builder: *?PeerBuilder,
    ) ParseError!void {
        var builder = peer_builder.* orelse return error.PeerHasNoPublicKey;
        peer_builder.* = null;
        defer builder.deinit(allocator);

        var peer = try builder.build(allocator);
        errdefer peer.deinit(allocator);
        try peers.append(allocator, peer);
    }
};

pub const ParseError = std.mem.Allocator.Error || error{
    InvalidLine,
    NoInterface,
    MultipleInterfaces,
    InterfaceHasNoPrivateKey,
    InterfaceHasInvalidPrivateKey,
    InterfaceHasInvalidListenPort,
    InterfaceHasInvalidAddress,
    InterfaceHasInvalidDNS,
    InterfaceHasInvalidMTU,
    InterfaceHasUnrecognizedKey,
    PeerHasNoPublicKey,
    PeerHasInvalidPublicKey,
    PeerHasInvalidPreSharedKey,
    PeerHasInvalidAllowedIP,
    PeerHasInvalidEndpoint,
    PeerHasInvalidPersistentKeepAlive,
    PeerHasUnrecognizedKey,
    MultiplePeersWithSamePublicKey,
    MultipleEntriesForKey,
    IdGeneration,
};

const InterfaceBuilder = struct {
    interface: api.WireGuardLocalInterface = .{},
    seen_keys: std.EnumSet(InterfaceKey) = std.EnumSet(InterfaceKey).initEmpty(),
    addresses: std.ArrayList(api.Subnet) = .empty,
    dns_servers: std.ArrayList(api.Address) = .empty,
    dns_domains: std.ArrayList(api.Address) = .empty,

    fn deinit(self: *InterfaceBuilder, allocator: std.mem.Allocator) void {
        self.interface.deinit(allocator);
        util.deinitList(api.Subnet, allocator, &self.addresses);
        util.deinitList(api.Address, allocator, &self.dns_servers);
        util.deinitList(api.Address, allocator, &self.dns_domains);
    }

    fn put(
        self: *InterfaceBuilder,
        allocator: std.mem.Allocator,
        raw_key: []const u8,
        value: []const u8,
    ) ParseError!void {
        const key = InterfaceKey.parse(raw_key) orelse return error.InterfaceHasUnrecognizedKey;
        if (!key.allowsMultiple() and self.seen_keys.contains(key)) return error.MultipleEntriesForKey;
        self.seen_keys.insert(key);

        switch (key) {
            .private_key => self.interface.private_key =
                try parseApiRawAlloc(api.WireGuardKey, allocator, value, error.InterfaceHasInvalidPrivateKey),
            .address => try appendCommaSeparatedApiValues(
                api.Subnet,
                allocator,
                &self.addresses,
                value,
                error.InterfaceHasInvalidAddress,
            ),
            .dns => try appendCommaSeparatedDNS(allocator, &self.dns_servers, &self.dns_domains, value),
            .mtu => self.interface.mtu =
                try parseInteger(u16, value, error.InterfaceHasInvalidMTU),
            .listen_port => self.interface.listen_port =
                try parseInteger(u16, value, error.InterfaceHasInvalidListenPort),
            // These legacy extension keys were also accepted-and-discarded by
            // the Swift parser. DNS protocol details live in DNSModule now, so
            // there is no lossless field to map them to here.
            .dns_over_https_url, .dns_over_tls_server_name => {},
        }
    }

    fn build(self: *InterfaceBuilder, allocator: std.mem.Allocator) ParseError!api.WireGuardLocalInterface {
        if (!self.seen_keys.contains(.private_key)) return error.InterfaceHasNoPrivateKey;

        self.interface.addresses = try self.addresses.toOwnedSlice(allocator);
        if (self.dns_servers.items.len > 0 or self.dns_domains.items.len > 0) {
            self.interface.dns = try self.buildDNS(allocator);
        }

        const interface = self.interface;
        self.interface = .{};
        return interface;
    }

    fn buildDNS(self: *InterfaceBuilder, allocator: std.mem.Allocator) ParseError!api.DNSModule {
        const servers = if (self.dns_servers.items.len > 0)
            try self.dns_servers.toOwnedSlice(allocator)
        else
            &.{};
        errdefer util.freeSlice(api.Address, allocator, servers);

        const domains = if (self.dns_domains.items.len > 0)
            try self.dns_domains.toOwnedSlice(allocator)
        else
            null;
        errdefer if (domains) |items| util.freeSlice(api.Address, allocator, items);

        return .{
            .id = try core.newId(),
            .protocol_type = .{ .cleartext = .{} },
            .servers = servers,
            .search_domains = domains,
        };
    }
};

const PeerBuilder = struct {
    peer: api.WireGuardRemoteInterface = .{},
    seen_keys: std.EnumSet(PeerKey) = std.EnumSet(PeerKey).initEmpty(),
    allowed_ips: std.ArrayList(api.Subnet) = .empty,

    fn deinit(self: *PeerBuilder, allocator: std.mem.Allocator) void {
        self.peer.deinit(allocator);
        util.deinitList(api.Subnet, allocator, &self.allowed_ips);
    }

    fn put(
        self: *PeerBuilder,
        allocator: std.mem.Allocator,
        raw_key: []const u8,
        value: []const u8,
    ) ParseError!void {
        const key = PeerKey.parse(raw_key) orelse return error.PeerHasUnrecognizedKey;
        if (!key.allowsMultiple() and self.seen_keys.contains(key)) return error.MultipleEntriesForKey;
        self.seen_keys.insert(key);

        switch (key) {
            .public_key => self.peer.public_key =
                try parseApiRawAlloc(api.WireGuardKey, allocator, value, error.PeerHasInvalidPublicKey),
            .pre_shared_key => self.peer.pre_shared_key =
                try parseApiRawAlloc(api.WireGuardKey, allocator, value, error.PeerHasInvalidPreSharedKey),
            .allowed_ips => try appendCommaSeparatedApiValues(
                api.Subnet,
                allocator,
                &self.allowed_ips,
                value,
                error.PeerHasInvalidAllowedIP,
            ),
            .endpoint => {
                // Do not use the generic Endpoint grammar directly here. It
                // splits on the last colon, whereas wg-quick follows
                // wireguard-tools' stricter grammar: an IPv6 host must be
                // bracketed (`[::1]:51820`) and an unbracketed endpoint splits
                // on its first colon. Keeping this validation local also
                // prevents spaces and other URL-host-invalid bytes from
                // reaching DNS resolution as a malformed hostname.
                if (!isWireGuardEndpoint(value)) return error.PeerHasInvalidEndpoint;
                self.peer.endpoint =
                    try parseApiRawAlloc(api.Endpoint, allocator, value, error.PeerHasInvalidEndpoint);
            },
            .persistent_keep_alive => self.peer.keep_alive =
                try parseInteger(u16, value, error.PeerHasInvalidPersistentKeepAlive),
        }
    }

    fn build(self: *PeerBuilder, allocator: std.mem.Allocator) ParseError!api.WireGuardRemoteInterface {
        if (!self.seen_keys.contains(.public_key)) return error.PeerHasNoPublicKey;
        self.peer.allowed_ips = try self.allowed_ips.toOwnedSlice(allocator);

        const peer = self.peer;
        self.peer = .{};
        return peer;
    }
};

const Section = enum {
    none,
    interface,
    peer,
};

const InterfaceKey = enum {
    private_key,
    listen_port,
    address,
    dns,
    dns_over_https_url,
    dns_over_tls_server_name,
    mtu,

    fn parse(raw: []const u8) ?InterfaceKey {
        if (std.ascii.eqlIgnoreCase(raw, "privatekey")) return .private_key;
        if (std.ascii.eqlIgnoreCase(raw, "listenport")) return .listen_port;
        if (std.ascii.eqlIgnoreCase(raw, "address")) return .address;
        if (std.ascii.eqlIgnoreCase(raw, "dns")) return .dns;
        if (std.ascii.eqlIgnoreCase(raw, "dnsoverhttpsurl")) return .dns_over_https_url;
        if (std.ascii.eqlIgnoreCase(raw, "dnsovertlsservername")) return .dns_over_tls_server_name;
        if (std.ascii.eqlIgnoreCase(raw, "mtu")) return .mtu;
        return null;
    }

    fn allowsMultiple(self: InterfaceKey) bool {
        return self == .address or self == .dns;
    }
};

const PeerKey = enum {
    public_key,
    pre_shared_key,
    allowed_ips,
    endpoint,
    persistent_keep_alive,

    fn parse(raw: []const u8) ?PeerKey {
        if (std.ascii.eqlIgnoreCase(raw, "publickey")) return .public_key;
        if (std.ascii.eqlIgnoreCase(raw, "presharedkey")) return .pre_shared_key;
        if (std.ascii.eqlIgnoreCase(raw, "allowedips")) return .allowed_ips;
        if (std.ascii.eqlIgnoreCase(raw, "endpoint")) return .endpoint;
        if (std.ascii.eqlIgnoreCase(raw, "persistentkeepalive")) return .persistent_keep_alive;
        return null;
    }

    fn allowsMultiple(self: PeerKey) bool {
        return self == .allowed_ips;
    }
};

fn ensureUniquePeerPublicKeys(peers: []const api.WireGuardRemoteInterface) ParseError!void {
    for (peers, 0..) |lhs, lhs_index| {
        for (peers[lhs_index + 1 ..]) |rhs| {
            if (std.mem.eql(u8, lhs.public_key.raw, rhs.public_key.raw)) {
                return error.MultiplePeersWithSamePublicKey;
            }
        }
    }
}

fn appendCommaSeparatedApiValues(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(T),
    value: []const u8,
    invalid_error: ParseError,
) ParseError!void {
    var items = std.mem.splitScalar(u8, value, ',');
    while (items.next()) |raw_item| {
        const item = util.trim(raw_item);
        if (item.len == 0) continue;
        const parsed = try parseApiRawAlloc(T, allocator, item, invalid_error);
        errdefer {
            var mutable = parsed;
            mutable.deinit(allocator);
        }
        try list.append(allocator, parsed);
    }
}

fn appendCommaSeparatedDNS(
    allocator: std.mem.Allocator,
    servers: *std.ArrayList(api.Address),
    domains: *std.ArrayList(api.Address),
    value: []const u8,
) ParseError!void {
    var items = std.mem.splitScalar(u8, value, ',');
    while (items.next()) |raw_item| {
        const item = util.trim(raw_item);
        if (item.len == 0) continue;
        const address = try parseApiRawAlloc(api.Address, allocator, item, error.InterfaceHasInvalidDNS);
        errdefer {
            var mutable = address;
            mutable.deinit(allocator);
        }
        if (address.isIPAddress()) {
            try servers.append(allocator, address);
        } else {
            // wg-quick overloads DNS= with both resolver addresses and search
            // domains. Preserve that split in the typed DNSModule.
            try domains.append(allocator, address);
        }
    }
}

fn parseApiRawAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: []const u8,
    invalid_error: ParseError,
) ParseError!T {
    return (try T.parseRawAlloc(allocator, value)) orelse invalid_error;
}

fn parseInteger(
    comptime T: type,
    value: []const u8,
    invalid_error: ParseError,
) ParseError!T {
    return std.fmt.parseInt(T, value, 10) catch invalid_error;
}

/// Mirrors `Endpoint(withWgRepresentation:)` in the Swift implementation,
/// whose parsing rules are in turn based on wireguard-tools' `parse_endpoint`.
/// The generic API Endpoint intentionally remains more permissive because its
/// JSON representation is shared by protocols other than WireGuard.
fn isWireGuardEndpoint(raw: []const u8) bool {
    if (raw.len == 0) return false;

    const host: []const u8, const port: []const u8 = if (raw[0] == '[') value: {
        const relative_end = std.mem.indexOfScalar(u8, raw[1..], ']') orelse return false;
        const end = relative_end + 1;
        if (end + 1 >= raw.len or raw[end + 1] != ':') return false;
        break :value .{ raw[1..end], raw[end + 2 ..] };
    } else value: {
        const separator = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
        break :value .{ raw[0..separator], raw[separator + 1 ..] };
    };

    _ = std.fmt.parseInt(u16, port, 10) catch return false;
    if (host.len == 0) return false;
    for (host) |byte| {
        if (!isURLHostAllowed(byte)) return false;
    }
    return true;
}

/// Foundation's `CharacterSet.urlHostAllowed` is deliberately narrower than
/// RFC percent-encoded URLs: `%`, `/`, `@`, `#`, and non-ASCII scalars are not
/// accepted by the Swift WireGuard parser. Keep the same ASCII set here.
fn isURLHostAllowed(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', '-', '.', ':', ';', '=', '[', ']', '_', '~' => true,
        else => false,
    };
}

fn importParserContext(context: ?core.ImportContext) Parser.Context {
    const import_context = context orelse return .{};
    var parser_context = if (import_context.cast(Parser.Context, .WireGuard)) |value| value.* else Parser.Context{};
    if (import_context.parse_error_info) |info| {
        parser_context.parse_error_info = info;
    }
    return parser_context;
}

fn setRecognizedType(context: ?core.ImportContext) void {
    const import_context = context orelse return;
    import_context.setRecognizedType(.WireGuard);
}
