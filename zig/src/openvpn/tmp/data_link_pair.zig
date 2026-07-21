// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const DataLink = @import("data_link.zig").DataLink;

/// A data-link view bound to the currently selected three-bit key.
pub const DataLinkPair = struct {
    link: *DataLink,
    key: u8,

    pub fn send(
        self: DataLinkPair,
        packets: []const []const u8,
        key: ?u8,
        timeout_ms: ?u64,
    ) anyerror!void {
        try self.link.send(packets, key orelse self.key, timeout_ms);
    }

    pub fn receive(
        self: DataLinkPair,
        packets: []const []const u8,
        key: u8,
    ) anyerror!void {
        try self.link.receive(packets, key);
    }
};
