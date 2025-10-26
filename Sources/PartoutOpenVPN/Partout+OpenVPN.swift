// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
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

// MARK: - Mapping

extension OpenVPNSessionError: PartoutErrorMappable {
    public var asPartoutError: PartoutError {
        PartoutError(errorCode, self)
    }

    private var errorCode: PartoutError.Code {
        switch self {
        case .negotiationTimeout, .pingTimeout, .writeTimeout:
            return .timeout

        case .badCredentials:
            return .authentication

        case .serverCompression:
            return .OpenVPN.compressionMismatch

        case .serverShutdown:
            return .OpenVPN.serverShutdown

        case .noRouting:
            return .OpenVPN.noRouting

        case .native(let code):
            switch code {
            case .cryptoRandomGenerator, .cryptoEncryption, .cryptoHMAC:
                return .crypto

            case .cryptoAlgorithm:
                return .OpenVPN.unsupportedAlgorithm

#if OPENVPN_LEGACY
            case .tlscaRead:
                return .OpenVPN.tlsFailure
#endif

            case .tlscaUse, .tlscaPeerVerification,
                    .tlsClientCertificateRead, .tlsClientCertificateUse,
                    .tlsClientKeyRead, .tlsClientKeyUse,
                    .tlsServerCertificate, .tlsServerEKU, .tlsServerHost,
                    .tlsHandshake:
                return .OpenVPN.tlsFailure

            case .dataPathCompression:
                return .OpenVPN.compressionMismatch

            default:
                break
            }

        default:
            break
        }
        return .OpenVPN.connectionFailure
    }
}

// MARK: - Debugging

#if OPENVPN_LEGACY
internal import PartoutOpenVPN_ObjC

extension OpenVPNErrorCode: @retroactive CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue.description
    }
}
#endif
