// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Primary test root for file-local tests in `openvpn/internal`.

const c_crypto = @import("c/exports.zig").crypto;
const std = @import("std");

pub export fn partout_log(_: c_int, _: [*:0]const u8) void {}

// The regular mock-only Zig test build intentionally does not link the three
// optional production crypto backends. These fallbacks let declaration tests
// cover runtime backend selection without copying any crypto implementation.
pub export fn pp_crypto_fnt_openssl() c_crypto.pp_crypto_fnt {
    return c_crypto.pp_crypto_fnt_mock();
}

pub export fn pp_crypto_fnt_mbedtls() c_crypto.pp_crypto_fnt {
    return c_crypto.pp_crypto_fnt_mock();
}

pub export fn pp_crypto_fnt_native() c_crypto.pp_crypto_fnt {
    return c_crypto.pp_crypto_fnt_mock();
}

test {
    inline for (.{
        @import("openvpn/internal/auth.zig"),
        @import("openvpn/internal/configuration.zig"),
        @import("openvpn/internal/constants.zig"),
        @import("openvpn/internal/control.zig"),
        @import("openvpn/internal/crypto.zig"),
        @import("openvpn/internal/data.zig"),
        @import("openvpn/internal/errors.zig"),
        @import("openvpn/internal/helpers.zig"),
        @import("openvpn/internal/packet.zig"),
        @import("openvpn/internal/processing.zig"),
        @import("openvpn/internal/push.zig"),
        @import("openvpn/internal/serialization.zig"),
        @import("openvpn/internal/session_context.zig"),
        @import("openvpn/internal/session_negotiator.zig"),
        @import("openvpn/internal/session.zig"),
        @import("openvpn/internal/settings.zig"),
        @import("openvpn/internal/tls.zig"),
    }) |module| std.testing.refAllDecls(module);
}
