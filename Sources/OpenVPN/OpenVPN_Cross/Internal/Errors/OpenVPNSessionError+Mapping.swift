//
//  OpenVPNSessionError+Mapping.swift
//  Partout
//
//  Created by Davide De Rosa on 6/15/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

internal import _PartoutVendorsPortable
#if canImport(_PartoutOpenVPNOpenSSL_ObjC)
internal import _PartoutOpenVPNOpenSSL_ObjC
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
