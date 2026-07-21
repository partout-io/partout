// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const gen = @import("api_generated.zig");
const util = @import("util.zig");
const uuid = @import("uuid.zig");

const AllocError = std.mem.Allocator.Error;
const DecodeError = gen.DecodeError;
const EncodeError = gen.EncodeError;
const JsonStringifyError = std.json.Stringify.Error;

pub const Address = struct {
    raw: []const u8 = "",
    family: Family = .hostname,
    owned: bool = false,

    pub const Family = enum {
        v4,
        v6,
        hostname,

        fn ofRaw(raw: []const u8) Family {
            const parsed = std.Io.net.IpAddress.parse(raw, 0) catch return .hostname;
            return switch (parsed) {
                .ip4 => .v4,
                .ip6 => .v6,
            };
        }

        fn ofZ(c_address: [*:0]const u8) Family {
            return ofRaw(std.mem.span(c_address));
        }

        fn isValidPrefixLength(self: Family, prefix_length: u8) bool {
            return switch (self) {
                .v4 => prefix_length <= 32,
                .v6 => prefix_length <= 128,
                .hostname => false,
            };
        }
    };

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!Address {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!Address {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return (try parseRawAlloc(allocator, raw)) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?Address {
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;
        return .{
            .raw = trimmed,
            .family = Family.ofRaw(trimmed),
        };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?Address {
        const parsed = parseRaw(raw) orelse return null;
        return .{
            .raw = try allocator.dupe(u8, parsed.raw),
            .family = parsed.family,
            .owned = true,
        };
    }

    pub fn deinit(self: *Address, allocator: std.mem.Allocator) void {
        if (self.owned and self.raw.len > 0) allocator.free(self.raw);
    }

    pub fn isIPAddress(self: Address) bool {
        return self.family != .hostname;
    }

    pub fn jsonStringify(self: Address, jw: anytype) JsonStringifyError!void {
        try jw.write(self.raw);
    }

    fn isIPv4(self: Address) bool {
        return self.family == .v4;
    }

    fn isIPv6(self: Address) bool {
        return self.family == .v6;
    }

    fn isHostname(self: Address) bool {
        return self.family == .hostname;
    }

    fn isEndpointComponent(raw_address: []const u8) bool {
        if (raw_address.len == 0) return false;
        for (raw_address) |byte| {
            if (std.ascii.isWhitespace(byte)) return false;
        }
        return true;
    }
};

pub const Endpoint = struct {
    address: []const u8 = "",
    port: u16 = 0,
    owned: bool = false,

    pub fn clone(self: Endpoint, allocator: std.mem.Allocator) error{OutOfMemory}!Endpoint {
        return .{
            .address = try allocator.dupe(u8, self.address),
            .port = self.port,
            .owned = true,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!Endpoint {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!Endpoint {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return (try parseRawAlloc(allocator, raw)) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?Endpoint {
        const separator = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return null;
        if (separator + 1 == raw.len) return null;
        const raw_address = unbracketIPv6(raw[0..separator]);
        const port = std.fmt.parseInt(u16, raw[separator + 1 ..], 10) catch return null;
        const parsed_address = Address.parseRaw(raw_address) orelse return null;
        return .{
            .address = parsed_address.raw,
            .port = port,
        };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?Endpoint {
        const parsed = parseRaw(raw) orelse return null;
        return .{
            .address = try allocator.dupe(u8, parsed.address),
            .port = parsed.port,
            .owned = true,
        };
    }

    pub fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        if (self.owned and self.address.len > 0) allocator.free(self.address);
    }

    pub fn eql(self: Endpoint, other: Endpoint) bool {
        return self.port == other.port and std.mem.eql(u8, self.address, other.address);
    }

    pub fn rawAlloc(self: Endpoint, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        if (Address.parseRaw(self.address)) |parsed_address| {
            if (parsed_address.isIPv6()) {
                return std.fmt.allocPrint(allocator, "[{s}]:{}", .{ self.address, self.port });
            }
        }
        return std.fmt.allocPrint(allocator, "{s}:{}", .{ self.address, self.port });
    }

    pub fn jsonStringify(self: Endpoint, jw: anytype) JsonStringifyError!void {
        if (Address.parseRaw(self.address)) |parsed_address| {
            if (parsed_address.isIPv6()) {
                try jw.print("\"[{s}]:{}\"", .{ self.address, self.port });
                return;
            }
        }
        try jw.print("\"{s}:{}\"", .{ self.address, self.port });
    }

    fn unbracketIPv6(raw: []const u8) []const u8 {
        if (raw.len < 2) return raw;
        if (raw[0] != '[' or raw[raw.len - 1] != ']') return raw;
        return raw[1 .. raw.len - 1];
    }
};

pub const EndpointProtocol = struct {
    socket_type: gen.IPSocketType = .udp,
    port: u16 = 0,

    pub fn init(socket_type: gen.IPSocketType, port: u16) EndpointProtocol {
        return .{
            .socket_type = socket_type,
            .port = port,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!EndpointProtocol {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(_: std.mem.Allocator, value: std.json.Value) DecodeError!EndpointProtocol {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return parseRaw(raw) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?EndpointProtocol {
        const separator = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, raw[separator + 1 ..], ':') != null) return null;
        const socket_type = gen.IPSocketType.parseFromRaw(raw[0..separator]) orelse return null;
        const port = std.fmt.parseInt(u16, raw[separator + 1 ..], 10) catch return null;
        return init(socket_type, port);
    }

    pub fn rawAlloc(self: EndpointProtocol, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{}", .{
            self.socket_type.raw(),
            self.port,
        });
    }

    pub fn jsonStringify(self: EndpointProtocol, jw: anytype) JsonStringifyError!void {
        try jw.print("\"{s}:{}\"", .{ self.socket_type.raw(), self.port });
    }

    fn plainSocketType(self: EndpointProtocol) gen.SocketType {
        return switch (self.socket_type) {
            .udp, .udp4, .udp6 => .udp,
            .tcp, .tcp4, .tcp6 => .tcp,
        };
    }
};

pub const ExtendedEndpoint = struct {
    address: []const u8 = "",
    proto: EndpointProtocol = .{},
    owned: bool = false,

    pub fn init(raw_address: []const u8, proto: EndpointProtocol) ?ExtendedEndpoint {
        const parsed_address = Address.parseRaw(raw_address) orelse return null;
        return .{
            .address = parsed_address.raw,
            .proto = proto,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!ExtendedEndpoint {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!ExtendedEndpoint {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return (try parseRawAlloc(allocator, raw)) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?ExtendedEndpoint {
        const port_separator = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return null;
        const type_separator = std.mem.lastIndexOfScalar(u8, raw[0..port_separator], ':') orelse return null;
        const raw_address = raw[0..type_separator];
        if (!Address.isEndpointComponent(raw_address)) return null;
        const parsed_address = Address.parseRaw(raw_address) orelse return null;
        const socket_type = gen.IPSocketType.parseFromRaw(raw[type_separator + 1 .. port_separator]) orelse return null;
        const port = std.fmt.parseInt(u16, raw[port_separator + 1 ..], 10) catch return null;
        return .{
            .address = parsed_address.raw,
            .proto = EndpointProtocol.init(socket_type, port),
        };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?ExtendedEndpoint {
        const parsed = parseRaw(raw) orelse return null;
        return .{
            .address = try allocator.dupe(u8, parsed.address),
            .proto = parsed.proto,
            .owned = true,
        };
    }

    pub fn deinit(self: *ExtendedEndpoint, allocator: std.mem.Allocator) void {
        if (self.owned and self.address.len > 0) allocator.free(self.address);
    }

    pub fn rawAlloc(self: ExtendedEndpoint, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}:{}", .{
            self.address,
            self.proto.socket_type.raw(),
            self.proto.port,
        });
    }

    pub fn plainSocketType(self: ExtendedEndpoint) gen.SocketType {
        return self.proto.plainSocketType();
    }

    pub fn jsonStringify(self: ExtendedEndpoint, jw: anytype) JsonStringifyError!void {
        try jw.print("\"{s}:{s}:{}\"", .{
            self.address,
            self.proto.socket_type.raw(),
            self.proto.port,
        });
    }
};

pub const OpenVPNCryptoContainer = struct {
    pem: []const u8 = "",
    owned: bool = false,

    const begin_marker = "-----BEGIN ";

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!OpenVPNCryptoContainer {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!OpenVPNCryptoContainer {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return try parseRawAlloc(allocator, raw);
    }

    pub fn parseRaw(raw: []const u8) OpenVPNCryptoContainer {
        const offset = std.mem.indexOf(u8, raw, begin_marker) orelse return .{};
        return .{ .pem = raw[offset..] };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) AllocError!OpenVPNCryptoContainer {
        const parsed = parseRaw(raw);
        return .{
            .pem = try allocator.dupe(u8, parsed.pem),
            .owned = true,
        };
    }

    pub fn deinit(self: *OpenVPNCryptoContainer, allocator: std.mem.Allocator) void {
        if (self.owned and self.pem.len > 0) allocator.free(self.pem);
    }

    pub fn isEncrypted(self: OpenVPNCryptoContainer) bool {
        return std.mem.indexOf(u8, self.pem, "ENCRYPTED") != null;
    }

    pub fn jsonStringify(self: OpenVPNCryptoContainer, jw: anytype) JsonStringifyError!void {
        try jw.write(self.pem);
    }
};

pub const SecureData = struct {
    base64: []const u8 = "",
    owned: bool = false,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!SecureData {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!SecureData {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return (try parseRawAlloc(allocator, raw)) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?SecureData {
        _ = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return null;
        return .{ .base64 = raw };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?SecureData {
        const parsed = parseRaw(raw) orelse return null;
        return .{
            .base64 = try allocator.dupe(u8, parsed.base64),
            .owned = true,
        };
    }

    pub fn deinit(self: *SecureData, allocator: std.mem.Allocator) void {
        if (self.owned and self.base64.len > 0) allocator.free(self.base64);
    }

    pub fn jsonStringify(self: SecureData, jw: anytype) JsonStringifyError!void {
        try jw.write(self.base64);
    }
};

pub const Subnet = struct {
    address: Address = .{},
    prefix_length: u8 = 0,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!Subnet {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!Subnet {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return (try parseRawAlloc(allocator, raw)) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?Subnet {
        var parts = std.mem.splitScalar(u8, raw, '/');
        const raw_address = parts.next() orelse return null;
        const parsed_address = Address.parseRaw(raw_address) orelse return null;
        if (!parsed_address.isIPAddress()) return null;

        const raw_prefix = parts.next();
        if (parts.next() != null) return null;

        const prefix: u8 = if (raw_prefix) |value|
            std.fmt.parseInt(u8, value, 10) catch return null
        else switch (parsed_address.family) {
            .v4 => 32,
            .v6 => 128,
            .hostname => unreachable,
        };
        if (!parsed_address.family.isValidPrefixLength(prefix)) return null;
        return .{
            .address = parsed_address,
            .prefix_length = prefix,
        };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?Subnet {
        const parsed = parseRaw(raw) orelse return null;
        return .{
            .address = (try Address.parseRawAlloc(allocator, parsed.address.raw)) orelse return null,
            .prefix_length = parsed.prefix_length,
        };
    }

    pub fn deinit(self: *Subnet, allocator: std.mem.Allocator) void {
        self.address.deinit(allocator);
    }

    pub fn rawAlloc(self: Subnet, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{}", .{ self.address.raw, self.prefix_length });
    }

    pub fn networkRawAlloc(self: Subnet, allocator: std.mem.Allocator) EncodeError![]u8 {
        const network = switch (self.address.family) {
            .v4 => try ipv4NetworkRawAlloc(allocator, self.address.raw, self.prefix_length),
            .v6 => try ipv6NetworkRawAlloc(allocator, self.address.raw, self.prefix_length),
            .hostname => return error.InvalidModel,
        };
        defer allocator.free(network);
        return std.fmt.allocPrint(allocator, "{s}/{}", .{ network, self.prefix_length });
    }

    pub fn jsonStringify(self: Subnet, jw: anytype) JsonStringifyError!void {
        try jw.print("\"{s}/{}\"", .{ self.address.raw, self.prefix_length });
    }

    fn ipv4Netmask(prefix: u8) u32 {
        if (prefix == 0) return 0;
        const shift: u5 = @intCast(32 - prefix);
        return @as(u32, std.math.maxInt(u32)) << shift;
    }

    fn ipv4NetworkRawAlloc(
        allocator: std.mem.Allocator,
        raw_address: []const u8,
        prefix: u8,
    ) EncodeError![]u8 {
        const parsed = std.Io.net.Ip4Address.parse(raw_address, 0) catch return error.InvalidModel;
        const raw =
            (@as(u32, parsed.bytes[0]) << 24) |
            (@as(u32, parsed.bytes[1]) << 16) |
            (@as(u32, parsed.bytes[2]) << 8) |
            @as(u32, parsed.bytes[3]);
        const network = raw & ipv4Netmask(prefix);
        return std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{
            (network >> 24) & 0xff,
            (network >> 16) & 0xff,
            (network >> 8) & 0xff,
            network & 0xff,
        });
    }

    fn ipv6NetworkRawAlloc(
        allocator: std.mem.Allocator,
        raw_address: []const u8,
        prefix: u8,
    ) EncodeError![]u8 {
        var parsed = std.Io.net.Ip6Address.parse(raw_address, 0) catch return error.InvalidModel;
        var full_bytes: usize = prefix / 8;
        if (full_bytes < parsed.bytes.len) {
            const remaining_bits = prefix % 8;
            if (remaining_bits > 0) {
                const shift: u3 = @intCast(8 - remaining_bits);
                parsed.bytes[full_bytes] &= @as(u8, 0xff) << shift;
                full_bytes += 1;
            }
            @memset(parsed.bytes[full_bytes..], 0);
        }
        const unresolved = std.Io.net.Ip6Address.Unresolved{
            .bytes = parsed.bytes,
            .interface_name = null,
        };
        return std.fmt.allocPrint(allocator, "{f}", .{unresolved});
    }
};

pub const WireGuardKey = struct {
    raw: []const u8 = "",
    owned: bool = false,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!WireGuardKey {
        var parsed = try util.parseJsonValue(allocator, text);
        defer parsed.deinit();
        return parseValue(allocator, parsed.value);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!WireGuardKey {
        const raw = stringValue(value) orelse return error.InvalidModel;
        return (try parseRawAlloc(allocator, raw)) orelse error.InvalidModel;
    }

    pub fn parseRaw(raw: []const u8) ?WireGuardKey {
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return null;
        if (decoded_size != 32) return null;
        var decoded: [32]u8 = undefined;
        std.base64.standard.Decoder.decode(decoded[0..], raw) catch return null;
        return .{ .raw = raw };
    }

    pub fn parseRawAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?WireGuardKey {
        const parsed = parseRaw(raw) orelse return null;
        return .{
            .raw = try allocator.dupe(u8, parsed.raw),
            .owned = true,
        };
    }

    pub fn deinit(self: *WireGuardKey, allocator: std.mem.Allocator) void {
        if (self.owned and self.raw.len > 0) allocator.free(self.raw);
    }

    pub fn hexAlloc(self: WireGuardKey, allocator: std.mem.Allocator) EncodeError![]u8 {
        const size = std.base64.standard.Decoder.calcSizeForSlice(self.raw) catch return error.InvalidModel;
        if (size != 32) return error.InvalidModel;
        var decoded: [32]u8 = undefined;
        std.base64.standard.Decoder.decode(&decoded, self.raw) catch return error.InvalidModel;
        const hex = std.fmt.bytesToHex(decoded, .lower);
        return try allocator.dupe(u8, &hex);
    }

    pub fn jsonStringify(self: WireGuardKey, jw: anytype) JsonStringifyError!void {
        try jw.write(self.raw);
    }
};

pub fn defaultValue(comptime T: type) T {
    if (T == Address) return .{};
    if (T == Endpoint) return .{};
    if (T == EndpointProtocol) return .{};
    if (T == ExtendedEndpoint) return .{};
    if (T == OpenVPNCryptoContainer) return .{};
    if (T == SecureData) return .{};
    if (T == Subnet) return .{};
    if (T == WireGuardKey) return .{};

    switch (@typeInfo(T)) {
        .int, .comptime_int => return 0,
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) return "";
        },
        else => {},
    }
    @compileError("unsupported manual OpenAPI default type: " ++ @typeName(T));
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}
