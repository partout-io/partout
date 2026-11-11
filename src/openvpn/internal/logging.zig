// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core_mod = @import("../../core/exports.zig");
const configuration_mod = @import("configuration.zig");

const api = core_mod.api;
const log = core_mod.logging;

pub fn logConfiguration(
    value: *const api.OpenVPNConfiguration,
    is_local: bool,
) void {
    if (is_local) {
        if (value.remotes) |remotes|
            log.writef(.debug, "\tRemotes: {s}", .{remotes});
    } else {
        if (value.ipv4) |ipv4| {
            log.writef(.debug, "\tIPv4: {s}", .{ipv4});
        } else {
            log.write(.debug, "\tIPv4: not configured");
        }
        if (value.ipv6) |ipv6| {
            log.writef(.debug, "\tIPv6: {s}", .{ipv6});
        } else {
            log.write(.debug, "\tIPv6: not configured");
        }
    }
    if (value.routes4) |routes|
        log.writef(.debug, "\tRoutes (IPv4): {s}", .{routes});
    if (value.routes6) |routes|
        log.writef(.debug, "\tRoutes (IPv6): {s}", .{routes});

    if (value.cipher) |cipher| {
        log.writef(.debug, "\tCipher: {s}", .{cipher.raw()});
    } else if (is_local) {
        log.writef(.debug, "\tCipher: {s}", .{
            configuration_mod.fallbackCipher(value).raw(),
        });
    }
    if (value.digest) |digest| {
        log.writef(.debug, "\tDigest: {s}", .{digest.raw()});
    } else if (is_local) {
        log.writef(.debug, "\tDigest: {s}", .{
            configuration_mod.fallbackDigest(value).raw(),
        });
    }
    if (value.compression_framing) |framing| {
        log.writef(.debug, "\tCompression framing: {s}", .{@tagName(framing)});
    } else if (is_local) {
        log.writef(.debug, "\tCompression framing: {s}", .{
            @tagName(configuration_mod.fallbackCompressionFraming(value)),
        });
    }
    if (value.compression_algorithm) |algorithm| {
        log.writef(.debug, "\tCompression algorithm: {s}", .{@tagName(algorithm)});
    } else if (is_local) {
        log.writef(.debug, "\tCompression algorithm: {s}", .{
            @tagName(configuration_mod.fallbackCompressionAlgorithm(value)),
        });
    }

    if (is_local) {
        log.writef(.debug, "\tUsername authentication: {}", .{
            value.auth_user_pass orelse false,
        });
        log.writef(.debug, "\tStatic challenge: {}", .{
            value.static_challenge orelse false,
        });
        log.write(
            .debug,
            if (value.client_certificate != null)
                "\tClient verification: enabled"
            else
                "\tClient verification: disabled",
        );
        if (value.tls_wrap) |wrap| {
            log.writef(.debug, "\tTLS wrapping: {s}", .{wrap.strategy.raw()});
        } else {
            log.write(.debug, "\tTLS wrapping: disabled");
        }
        if (value.tls_security_level) |level| {
            log.writef(.debug, "\tTLS security level: {d}", .{level});
        } else {
            log.write(.debug, "\tTLS security level: default");
        }
    }

    logPositiveSeconds(
        "\tKeep-alive interval: ",
        value.keep_alive_interval,
        is_local,
    );
    logPositiveSeconds(
        "\tKeep-alive timeout: ",
        value.keep_alive_timeout,
        is_local,
    );
    logPositiveSeconds(
        "\tRenegotiation: ",
        value.renegotiates_after,
        is_local,
    );
    if (value.checks_eku orelse false) {
        log.write(.debug, "\tServer EKU verification: enabled");
    } else if (is_local) {
        log.write(.debug, "\tServer EKU verification: disabled");
    }
    if (value.checks_san_host orelse false) {
        if (value.san_host) |host|
            log.writef(
                .debug,
                "\tHost SAN verification: enabled ({s})",
                .{log.sensitive(host)},
            )
        else
            log.write(.debug, "\tHost SAN verification: enabled (-)");
    } else if (is_local) {
        log.write(.debug, "\tHost SAN verification: disabled");
    }

    if (value.randomize_endpoint orelse false)
        log.write(.debug, "\tRandomize endpoint: true");
    if (value.randomize_hostnames orelse false)
        log.write(.debug, "\tRandomize hostnames: true");

    if (value.routing_policies) |policies| {
        log.writef(.debug, "\tGateway: {any}", .{policies});
    } else if (is_local) {
        log.write(.debug, "\tGateway: not configured");
    }

    if (value.dns_servers) |servers| {
        if (servers.len > 0) {
            log.writef(.debug, "\tDNS: {s}", .{servers});
        } else if (is_local) {
            log.write(.debug, "\tDNS: not configured");
        }
    } else if (is_local) {
        log.write(.debug, "\tDNS: not configured");
    }
    if (value.dns_domain) |domain|
        log.writef(.debug, "\tDNS domain: {s}", .{log.sensitive(domain)});
    if (value.search_domains) |domains| {
        if (domains.len > 0)
            log.writef(.debug, "\tSearch domains: {s}", .{domains});
    }

    if (value.http_proxy) |proxy|
        log.writef(.debug, "\tHTTP proxy: {s}", .{proxy});
    if (value.https_proxy) |proxy|
        log.writef(.debug, "\tHTTPS proxy: {s}", .{proxy});
    if (value.proxy_auto_configuration_url) |url|
        log.writef(.debug, "\tPAC: {s}", .{log.sensitive(url)});
    if (value.proxy_bypass_domains) |domains| {
        if (domains.len > 0)
            log.writef(
                .debug,
                "\tProxy bypass domains: {s}",
                .{domains},
            );
    }

    if (value.mtu) |mtu| {
        log.writef(.debug, "\tMTU: {d}", .{mtu});
    } else if (is_local) {
        log.write(.debug, "\tMTU: default");
    }
    if (value.xor_method) |method|
        log.writef(.debug, "\tXOR: {s}", .{@tagName(std.meta.activeTag(method))});
    if (value.no_pull_mask) |mask|
        log.writef(.debug, "\tNot pulled: {any}", .{mask});
}

pub fn logNegotiatedOptions(value: *const api.OpenVPNConfiguration) void {
    log.write(.notice, "Negotiated options (remote overrides local)");
    if (value.cipher) |cipher|
        log.writef(.notice, "\tCipher: {s}", .{cipher.raw()});
    if (value.compression_framing) |framing|
        log.writef(.notice, "\tCompression framing: {s}", .{@tagName(framing)});
    if (value.compression_algorithm) |algorithm|
        log.writef(.notice, "\tCompression algorithm: {s}", .{@tagName(algorithm)});
    if (value.keep_alive_interval) |interval|
        log.logTimeSeconds(.notice, "\tKeep-alive interval: ", interval);
    if (value.keep_alive_timeout) |timeout|
        log.logTimeSeconds(.notice, "\tKeep-alive timeout: ", timeout);
}

fn logPositiveSeconds(
    comptime prefix: []const u8,
    value: ?f64,
    print_never: bool,
) void {
    if (value) |seconds| {
        if (seconds > 0) {
            log.logTimeSeconds(.debug, prefix, seconds);
            return;
        }
    }
    if (print_never) log.write(.debug, prefix ++ "never");
}

pub fn pushReply(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]const u8 {
    return pushReplyString(allocator, value.original);
}

pub fn pushReplyString(
    allocator: std.mem.Allocator,
    string: []const u8,
) ![]const u8 {
    if (log.logsPrivateData()) return allocator.dupe(u8, string);

    const marker = "auth-token ";
    const start = std.mem.indexOf(u8, string, marker) orelse
        return allocator.dupe(u8, string);
    const string_start = start + marker.len;
    const string_end = std.mem.indexOfScalarPos(
        u8,
        string,
        string_start,
        ',',
    ) orelse string.len;
    return std.mem.concat(allocator, u8, &.{
        string[0..string_start],
        log.redacted_value,
        string[string_end..],
    });
}
