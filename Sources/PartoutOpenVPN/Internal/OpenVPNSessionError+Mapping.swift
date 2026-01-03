// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
internal import _PartoutTLS_C

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
            // PPCryptoError
            if rawError is PPCryptoError {
                return .cryptoAlgorithm
            }
            // PPTLSError
            else if rawError is PPTLSError {
                return .tlsHandshake
            }
            // CCryptoError
            else if let cryptoError = rawError as? CCryptoError {
                switch cryptoError.code {
                case PPCryptoErrorEncryption:
                    return .cryptoEncryption
                case PPCryptoErrorHMAC:
                    return .cryptoHMAC
                default:
                    assertionFailure("Crypto error with unknown error code: \(cryptoError.code)")
                }
            }
            // OpenVPNDataPathError
            else if let dpError = rawError as? OpenVPNDataPathError {
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
                case OpenVPNDataPathErrorPeerIdMismatch:
                    return .dataPathPeerIdMismatch
                case OpenVPNDataPathErrorCompression:
                    return .dataPathCompression
                case OpenVPNDataPathErrorCrypto:
                    return .cryptoEncryption
                default:
                    assertionFailure("Data path error with unknown error code: \(dpError.code)")
                }
            }
            // CTLSError
            else if let tlsError = rawError as? CTLSError {
                switch tlsError.code {
                case PPTLSErrorCAUse:
                    return .tlscaUse
                case PPTLSErrorCAPeerVerification:
                    return .tlscaPeerVerification
                case PPTLSErrorClientCertificateRead:
                    return .tlsClientCertificateRead
                case PPTLSErrorClientCertificateUse:
                    return .tlsClientCertificateUse
                case PPTLSErrorClientKeyRead:
                    return .tlsClientKeyRead
                case PPTLSErrorClientKeyUse:
                    return .tlsClientKeyUse
                case PPTLSErrorHandshake:
                    return .tlsHandshake
                case PPTLSErrorServerEKU:
                    return .tlsServerEKU
                case PPTLSErrorServerHost:
                    return .tlsServerHost
                default:
                    fatalError()
                }
            }
            return .unknown
        }()
        self = .native(code: code)
    }
}
