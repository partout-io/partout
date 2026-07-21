// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! OpenVPN-specific C declarations used by the internal port.

pub const api = @cImport({
    @cInclude("openvpn/openvpn.h");
});
