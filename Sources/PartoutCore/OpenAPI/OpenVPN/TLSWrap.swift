// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {
    /// Holds parameters for TLS wrapping.
    public struct TLSWrap: Hashable, Codable, Sendable {
        public static let clientV2FileHead = "-----BEGIN OpenVPN tls-crypt-v2 client key-----"

        public static let clientV2FileFoot = "-----END OpenVPN tls-crypt-v2 client key-----"

        /// The wrapping strategy.
        public enum Strategy: String, Hashable, Codable, Sendable {

            /// Authenticates payload (--tls-auth).
            case auth

            /// Encrypts payload (--tls-crypt).
            case crypt

            /// Encrypts payload with a client-specific key (--tls-crypt-v2).
            case cryptV2 = "crypt-v2"
        }

        /// The wrapping strategy.
        public let strategy: Strategy

        /// The static encryption key.
        public let key: StaticKey

        /// The wrapped client key appended to initial tls-crypt-v2 packets.
        public let wrappedKey: SecureData?

        public init(strategy: Strategy, key: StaticKey, wrappedKey: SecureData? = nil) {
            precondition(strategy != .cryptV2 || wrappedKey != nil)
            self.strategy = strategy
            self.key = key
            self.wrappedKey = wrappedKey
        }
    }
}
