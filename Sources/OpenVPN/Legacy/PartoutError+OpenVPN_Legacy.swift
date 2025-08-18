// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_STATIC
internal import _PartoutOpenVPNLegacy_ObjC
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

            case .tlscaRead, .tlscaUse, .tlscaPeerVerification,
                    .tlsClientCertificateRead, .tlsClientCertificateUse,
                    .tlsClientKeyRead, .tlsClientKeyUse,
                    .tlsServerCertificate, .tlsServerEKU, .tlsServerHost,
                    .tlsHandshake:
                return .OpenVPN.tlsFailure

            case .dataPathCompression:
                return .OpenVPN.compressionMismatch

            default:
                return .OpenVPN.connectionFailure
            }

        default:
            return .OpenVPN.connectionFailure
        }
    }
}

// MARK: - Debugging

extension OpenVPNErrorCode: @retroactive CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue.description
    }
}
