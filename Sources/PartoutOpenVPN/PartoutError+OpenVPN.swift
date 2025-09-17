// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

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
