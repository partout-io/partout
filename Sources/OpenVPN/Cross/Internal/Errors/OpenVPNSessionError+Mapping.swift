// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutVendorsPortable
#if canImport(_PartoutOpenVPNLegacy_ObjC)
internal import _PartoutOpenVPNLegacy_ObjC
#endif
internal import _PartoutOpenVPN_C
import Foundation

extension OpenVPNSessionError {
    init(_ error: Error) {
        if let sessionError = error as? Self {
            self = sessionError
        } else {
            self.init(rawError: error)
        }
    }
}

private extension OpenVPNSessionError {
    init(rawError: Error) {
        let code: OpenVPNErrorCode = {
            // CryptoError
            if let cryptoError = rawError as? CryptoError {
                switch cryptoError {
                case .creation, .hmac:
                    return .cryptoAlgorithm
                }
            }
            // CCryptoError
            else if let cryptoError = rawError as? CCryptoError {
                switch cryptoError.code {
                case CryptoErrorEncryption:
                    return .cryptoEncryption
                case CryptoErrorHMAC:
                    return .cryptoHMAC
                default:
                    assertionFailure("Crypto error with unknown error code: \(cryptoError.code)")
                }
            }
            // DataPathError
            else if let dpError = rawError as? DataPathError {
                switch dpError {
                case .algorithm, .creation:
                    return .cryptoAlgorithm
                case .overflow:
                    return .dataPathOverflow
                }
            }
            // CDataPathError
            else if let dpError = rawError as? CDataPathError {
                switch dpError.code {
                case DataPathErrorPeerIdMismatch:
                    return .dataPathPeerIdMismatch
                case DataPathErrorCompression:
                    return .dataPathCompression
                case DataPathErrorCrypto:
                    return .cryptoEncryption
                default:
                    assertionFailure("Data path error with unknown error code: \(dpError.code)")
                }
            }
            // CTLSError
            else if let tlsError = rawError as? CTLSError {
                switch tlsError.code {
                case TLSErrorCAUse:
                    return .tlscaUse
                case TLSErrorCAPeerVerification:
                    return .tlscaPeerVerification
                case TLSErrorClientCertificateRead:
                    return .tlsClientCertificateRead
                case TLSErrorClientCertificateUse:
                    return .tlsClientCertificateUse
                case TLSErrorClientKeyRead:
                    return .tlsClientKeyRead
                case TLSErrorClientKeyUse:
                    return .tlsClientKeyUse
                case TLSErrorHandshake:
                    return .tlsHandshake
                case TLSErrorServerEKU:
                    return .tlsServerEKU
                case TLSErrorServerHost:
                    return .tlsServerHost
                default:
                    fatalError()
                }
            }
            return .unknown
        }()
        self = .internal(code)
    }
}
