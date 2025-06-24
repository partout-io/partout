//
//  DataPathError.swift
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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

internal import _PartoutCryptoOpenSSL_Cross
internal import _PartoutOpenVPNOpenSSL_C

enum DataPathError: Error {
    case algorithm

    case peerIdMismatch

    case overflow

    case compression

    case crypto(crypto_error_code)

    case unknown

    init(_ error: dp_error_t, asserting: Bool) {
        switch error.dp_code {
        case DataPathErrorNone:
            if asserting {
                assertionFailure()
            }
            self = .unknown
        case DataPathErrorPeerIdMismatch:
            self = .peerIdMismatch
        case DataPathErrorOverflow:
            self = .overflow
        case DataPathErrorCompression:
            self = .compression
        case DataPathErrorCrypto:
            self = .crypto(error.crypto_code)
        default:
            self = .unknown
        }
    }
}
