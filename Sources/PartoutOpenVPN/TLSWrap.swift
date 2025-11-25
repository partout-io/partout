// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {

    /// Holds parameters for TLS wrapping.
    public struct TLSWrap: Hashable, Codable, Sendable {

        /// The wrapping strategy.
        public enum Strategy: String, Hashable, Codable, Sendable {

            /// Authenticates payload (--tls-auth).
            case auth

            /// Encrypts payload (--tls-crypt).
            case crypt
        }

        /// The wrapping strategy.
        public let strategy: Strategy

        /// The static encryption key.
        public let key: StaticKey

        public init(strategy: Strategy, key: StaticKey) {
            self.strategy = strategy
            self.key = key
        }
    }
}
