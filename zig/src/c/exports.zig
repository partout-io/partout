// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const common = @cImport({
    @cInclude("portable/common.h");
    @cInclude("portable/lib.h");
    @cInclude("portable/prng.h");
    @cInclude("portable/zd.h");
});

pub const crypto = @cImport({
    @cInclude("crypto/crypto.h");
});

pub const io = @cImport({
    @cInclude("portable/mux.h");
    @cInclude("portable/socket.h");
    @cInclude("portable/tun.h");
});
