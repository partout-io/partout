// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension LoggerCategory {
    public static let openvpn = Self(rawValue: "openvpn")
}

extension TunnelEnvironmentKeys {
    public enum OpenVPN {
        public static let serverConfiguration = TunnelEnvironmentKey<PartoutOpenVPN.OpenVPN.Configuration>("OpenVPN.serverConfiguration")
    }
}

extension PartoutError.Code {
    public enum OpenVPN {
        public static let compressionMismatch = PartoutError.Code("OpenVPN.compressionMismatch")

        public static let connectionFailure = PartoutError.Code("OpenVPN.connectionFailure")

        public static let noRouting = PartoutError.Code("OpenVPN.noRouting")

        public static let otpRequired = PartoutError.Code("OpenVPN.otpRequired")

        public static let passphraseRequired = PartoutError.Code("OpenVPN.passphraseRequired")

        public static let serverShutdown = PartoutError.Code("OpenVPN.serverShutdown")

        public static let tlsFailure = PartoutError.Code("OpenVPN.tlsFailure")

        public static let unsupportedAlgorithm = PartoutError.Code("OpenVPN.unsupportedAlgorithm")

        public static let unsupportedOption = PartoutError.Code("OpenVPN.unsupportedOption")
    }
}
