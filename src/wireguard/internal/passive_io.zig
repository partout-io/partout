// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const c = @import("wireguard_c");
const posix = @import("passive_io_posix.zig");
const windows = @import("passive_io_windows.zig");

pub const PassiveIO = if (builtin.os.tag == .windows) windows.PassiveIO else posix.PassiveIO;

pub const testing = struct {
    pub const abi = c;
};
