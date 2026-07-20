// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const helpers = @import("source").abi_helpers;

const c = helpers.c;
const CompletionCode = c.partout_completion_code;
const InitArgs = c.partout_init_args;

test "ABI structs stay C-sized" {
    try std.testing.expect(@offsetOf(InitArgs, "logs_private_data") == 0);
    try std.testing.expect(@offsetOf(InitArgs, "logger") == @sizeOf(?*anyopaque));
    try std.testing.expect(@sizeOf(CompletionCode) == @sizeOf(c_int));
}
