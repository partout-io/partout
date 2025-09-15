// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
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

// MARK: - Mapping

extension WireGuardParseError: PartoutErrorMappable {
    public var asPartoutError: PartoutError {
        PartoutError(.parsing, self)
    }
}
