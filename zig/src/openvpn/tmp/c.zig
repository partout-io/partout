// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Single C-import identity shared by the temporary OpenVPN port.
//!
//! Keeping the crypto and OpenVPN declarations in one `@cImport` matters:
//! independently imported C declarations are distinct Zig types even when
//! their C spelling is identical.

pub const api = @cImport({
    @cInclude("portable/common.h");
    @cInclude("portable/prng.h");
    @cInclude("portable/zd.h");
    @cInclude("crypto/crypto.h");
    @cInclude("openvpn/openvpn.h");
});
