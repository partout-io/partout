// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const api = @import("api.zig");

pub const Adapter = enum {
    raw,
    raw_alloc,
    pem,
    hex,
    ip_settings,
    summary,
    json,
};

// API models cannot retroactively declare a logging formatter. Keep their
// type identity and representation together in this comptime adapter registry.
const adapters = .{
    .{ api.Address, Adapter.raw },
    .{ api.Endpoint, Adapter.raw_alloc },
    .{ api.ExtendedEndpoint, Adapter.raw_alloc },
    .{ api.OpenVPNCryptoContainer, Adapter.pem },
    .{ api.SecureData, Adapter.hex },
    .{ api.Subnet, Adapter.raw_alloc },
    .{ api.WireGuardKey, Adapter.raw },
    .{ api.IPSettings, Adapter.ip_settings },
    .{ api.DNSModule, Adapter.summary },
    .{ api.DNSModuleProtocolType, Adapter.summary },
    .{ api.DNSModuleProtocolTypeHttps, Adapter.summary },
    .{ api.DNSModuleProtocolTypeTls, Adapter.summary },
    .{ api.HTTPProxyModule, Adapter.summary },
    .{ api.IPModule, Adapter.summary },
    .{ api.OnDemandModule, Adapter.summary },
    .{ api.OpenVPNConfiguration, Adapter.summary },
    .{ api.OpenVPNCredentials, Adapter.summary },
    .{ api.OpenVPNModule, Adapter.summary },
    .{ api.OpenVPNObfuscationMethod, Adapter.summary },
    .{ api.OpenVPNObfuscationMethodObfuscate, Adapter.summary },
    .{ api.OpenVPNObfuscationMethodXormask, Adapter.summary },
    .{ api.OpenVPNStaticKey, Adapter.summary },
    .{ api.OpenVPNTLSWrap, Adapter.summary },
    .{ api.Profile, Adapter.summary },
    .{ api.Route, Adapter.json },
    .{ api.TaggedModule, Adapter.summary },
    .{ api.TunnelControllerOptions, Adapter.summary },
    .{ api.TunnelRemoteInfoWrapper, Adapter.summary },
    .{ api.WireGuardConfiguration, Adapter.summary },
    .{ api.WireGuardLocalInterface, Adapter.summary },
    .{ api.WireGuardModule, Adapter.summary },
    .{ api.WireGuardRemoteInterface, Adapter.summary },
};

pub fn adapter(comptime T: type) ?Adapter {
    inline for (adapters) |entry| {
        if (T == entry[0]) return entry[1];
    }
    return null;
}

/// Public summaries expose structure, never names, addresses, credentials or keys.
/// Private logging uses complete JSON representations instead.
pub fn summary(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    if (T == api.Profile) return allocator.print("Profile(id={s}, modules={d}, active={d})", .{ value.id, value.modules.len, value.active_modules_ids.len });
    if (T == api.TaggedModule) return allocator.print("{s}Module(id={s})", .{ @tagName(value), api.moduleId(&value) });
    if (T == api.OpenVPNConfiguration) return allocator.print("OpenVPNConfiguration(remotes={d}, cipher={s}, credentials={})", .{
        if (value.remotes) |items| items.len else 0,
        if (value.cipher) |cipher| cipher.raw() else "default",
        value.auth_user_pass orelse false,
    });
    if (T == api.WireGuardConfiguration) return allocator.print("WireGuardConfiguration(peers={d})", .{value.peers.len});
    const full_name = @typeName(T);
    const name = full_name[(std.mem.lastIndexOfScalar(u8, full_name, '.') orelse 0) + 1 ..];
    if (@typeInfo(T) == .@"struct" and @hasField(T, "id")) {
        return allocator.print("{s}(id={s})", .{ name, value.id });
    }
    return allocator.dupe(u8, name);
}
