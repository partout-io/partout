// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
#endif

extension OpenVPN {

    /// Represents a cryptographic container in PEM format.
    public struct CryptoContainer: Hashable, Sendable {
        private static let begin = "-----BEGIN "

        private static let end = "-----END "

        /// The content in PEM format (ASCII).
        public let pem: String

        public var isEncrypted: Bool {
            return pem.contains("ENCRYPTED")
        }

        public init(pem: String) {
            guard let beginRange = pem.range(of: CryptoContainer.begin) else {
                self.pem = ""
                return
            }
            self.pem = String(pem[beginRange.lowerBound...])
        }

        public func write(to url: URL) throws {
            try pem.write(to: url, atomically: true, encoding: .ascii)
        }

        public func decrypted(with decrypter: KeyDecrypter, passphrase: String) throws -> CryptoContainer {
            let decryptedPEM = try decrypter.decryptedKey(fromPEM: pem, passphrase: passphrase)
            return CryptoContainer(pem: decryptedPEM)
        }
    }
}

// MARK: - Codable

extension OpenVPN.CryptoContainer: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let pem = try container.decode(String.self)
        self.init(pem: pem)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }
}

// MARK: - SensitiveDebugStringConvertible

extension OpenVPN.CryptoContainer: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? pem : JSONEncoder.redactedValue
    }
}
