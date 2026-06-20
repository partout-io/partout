// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Container of all OpenVPN entities.
public enum OpenVPN {
}

extension LoggerCategory {
    public static let openvpn = Self(rawValue: "openvpn")
}

// XXX: Workaround for name clash
/// Alias for ``OpenVPN/Configuration``.
public typealias OpenVPNConfiguration = OpenVPN.Configuration
