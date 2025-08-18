// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_STATIC
import PartoutCore
#endif

extension LoggerCategory {
    public static let wireguard = Self(rawValue: "wireguard")
}

extension PartoutError.Code {
    public enum WireGuard {
        public static let emptyPeers = PartoutError.Code("WireGuard.emptyPeers")
    }
}
