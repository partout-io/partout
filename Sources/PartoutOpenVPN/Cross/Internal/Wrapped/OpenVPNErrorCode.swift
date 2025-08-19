// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(_PartoutOpenVPNLegacy_ObjC)
#if !PARTOUT_MONOLITH
internal import _PartoutOpenVPNLegacy_ObjC
#endif

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
