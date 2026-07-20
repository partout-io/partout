// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core_api;

test "recognizes connection-building module types" {
    try std.testing.expect(!api.typeBuildsConnection(.DNS));
    try std.testing.expect(!api.typeBuildsConnection(.HTTPProxy));
    try std.testing.expect(!api.typeBuildsConnection(.IP));
    try std.testing.expect(!api.typeBuildsConnection(.OnDemand));
    try std.testing.expect(api.typeBuildsConnection(.OpenVPN));
    try std.testing.expect(!api.typeBuildsConnection(.Provider));
    try std.testing.expect(api.typeBuildsConnection(.WireGuard));
    try std.testing.expect(!api.typeBuildsConnection(.Undefined));
}

test "reports tagged module ids and types" {
    const allocator = std.testing.allocator;

    inline for (modules) |case| {
        var module = try api.parseModule(allocator, case.json);
        defer module.deinit(allocator);

        try std.testing.expectEqual(case.module_type, api.moduleType(&module));
        const module_id = api.moduleId(&module);
        try std.testing.expectEqualStrings(case.id, module_id[0..]);
    }
}

test "parses profile behavior" {
    const allocator = std.testing.allocator;
    var behavior = try api.ProfileBehavior.parse(allocator,
        \\{"disconnectsOnSleep":true,"includesAllNetworks":false}
    );
    defer behavior.deinit(allocator);

    try std.testing.expect(behavior.disconnects_on_sleep);
    try std.testing.expectEqual(false, behavior.includes_all_networks.?);
}

const TaggedModuleCase = struct {
    json: []const u8,
    module_type: api.ModuleType,
    id: []const u8,
};

const modules = .{
    TaggedModuleCase{
        .json =
        \\{"type":"DNS","value":{"id":"00000000-0000-0000-0000-000000000102","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
        ,
        .module_type = .DNS,
        .id = "00000000-0000-0000-0000-000000000102",
    },
    TaggedModuleCase{
        .json =
        \\{"type":"HTTPProxy","value":{"id":"00000000-0000-0000-0000-000000000103","proxy":"10.0.0.20:3128","bypassDomains":[]}}
        ,
        .module_type = .HTTPProxy,
        .id = "00000000-0000-0000-0000-000000000103",
    },
    TaggedModuleCase{
        .json =
        \\{"type":"IP","value":{"id":"00000000-0000-0000-0000-000000000104","mtu":1380}}
        ,
        .module_type = .IP,
        .id = "00000000-0000-0000-0000-000000000104",
    },
    TaggedModuleCase{
        .json =
        \\{"type":"OnDemand","value":{"id":"00000000-0000-0000-0000-000000000105","policy":"including","withSSIDs":{},"withOtherNetworks":["mobile"]}}
        ,
        .module_type = .OnDemand,
        .id = "00000000-0000-0000-0000-000000000105",
    },
    TaggedModuleCase{
        .json =
        \\{"type":"OpenVPN","value":{"id":"00000000-0000-0000-0000-000000000106","configuration":{"remotes":[]}}}
        ,
        .module_type = .OpenVPN,
        .id = "00000000-0000-0000-0000-000000000106",
    },
    TaggedModuleCase{
        .json =
        \\{"type":"WireGuard","value":{"id":"00000000-0000-0000-0000-000000000107","configuration":{"interface":{"privateKey":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","addresses":[]},"peers":[]}}}
        ,
        .module_type = .WireGuard,
        .id = "00000000-0000-0000-0000-000000000107",
    },
};
