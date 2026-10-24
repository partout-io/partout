// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const net = @import("../../net/exports.zig");
const c = @import("wireguard_c");
const Endpoint = c.wg_endpoint;

pub fn validRead(packets: [*c]c.wg_read_packet, count: u32, request: usize) bool {
    if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return false;
    for (packets[0..count]) |packet| if (packet.data == null or packet.capacity == 0) return false;
    return true;
}

pub fn validWrite(side: net.Side, packets: [*c]const c.wg_packet, count: u32, request: usize) bool {
    if (request == 0 or count == 0 or count > c.WG_IO_MAX_BATCH or packets == null) return false;
    for (packets[0..count]) |packet| if (packet.size > 65535 or (packet.size != 0 and packet.data == null) or (side == .tun and packet.size == 0)) return false;
    return true;
}

pub fn toEndpoint(address: net.SocketAddress) Endpoint {
    return .{
        .address = address.address,
        .scope_id = address.scope_id,
        .port = address.port,
        .family = address.family,
    };
}

pub fn fromEndpoint(endpoint: Endpoint) !net.SocketAddress {
    if (endpoint.family != 4 and endpoint.family != 6) return error.InvalidAddressFamily;
    if (endpoint.family == 4 and endpoint.scope_id != 0) return error.InvalidScope;
    var address = std.mem.zeroes(net.SocketAddress);
    address.address = endpoint.address;
    address.scope_id = endpoint.scope_id;
    address.port = endpoint.port;
    address.family = endpoint.family;
    return address;
}
