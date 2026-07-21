// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Primary test root for file-local tests in `openvpn/internal`.

const c_crypto = @import("c/exports.zig").crypto;

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
    _ = @import("openvpn/internal/exports.zig");
}
