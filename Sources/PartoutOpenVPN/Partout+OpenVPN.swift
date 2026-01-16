// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import PartoutCore
@_exported import PartoutOS
#endif

extension LoggerCategory {
    public static let openvpn = Self(rawValue: "openvpn")
}

// XXX: Workaround for name clash
/// Alias for ``OpenVPN/Configuration``.
public typealias OpenVPNConfiguration = OpenVPN.Configuration

extension TunnelEnvironmentKeys {
    public enum OpenVPN {
        public static let serverConfiguration = TunnelEnvironmentKey<OpenVPNConfiguration>("OpenVPN.serverConfiguration")
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
