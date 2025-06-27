//
//  OpenVPNErrorCode.swift
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

#if canImport(_PartoutOpenVPNOpenSSL_ObjC)
internal import _PartoutOpenVPNOpenSSL_ObjC

extension OpenVPNErrorCode: @retroactive CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue.description
    }
}
#else
enum OpenVPNErrorCode: Int {
    case cryptoRandomGenerator       = 101
    case cryptoHMAC                  = 102
    case cryptoEncryption            = 103
    case cryptoAlgorithm             = 104
    case tlscaRead                   = 201
    case tlscaUse                    = 202
    case tlscaPeerVerification       = 203
    case tlsClientCertificateRead    = 204
    case tlsClientCertificateUse     = 205
    case tlsClientKeyRead            = 206
    case tlsClientKeyUse             = 207
    case tlsHandshake                = 210
    case tlsServerCertificate        = 211
    case tlsServerEKU                = 212
    case tlsServerHost               = 213
    case dataPathOverflow            = 301
    case dataPathPeerIdMismatch      = 302
    case dataPathCompression         = 303
    case unknown                     = 999
}

extension OpenVPNErrorCode: CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue.description
    }
}
#endif
