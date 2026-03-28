// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {

    /// Holds parameters for TLS wrapping.
    public struct TLSWrap: Hashable, Codable, Sendable {
        private static let clientV2FileHead = "-----BEGIN OpenVPN tls-crypt-v2 client key-----"

        private static let clientV2FileFoot = "-----END OpenVPN tls-crypt-v2 client key-----"

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

        /// Initializes from a tls-crypt-v2 client key file.
        public init?(clientKeyV2File file: String) {
            guard let pair = Self.clientKeyV2(file: file) else {
                return nil
            }
            self.init(strategy: .cryptV2, key: pair.key, wrappedKey: pair.wrappedKey)
        }
    }
}

extension OpenVPN.TLSWrap {
    static func clientKeyV2(file: String) -> (key: OpenVPN.StaticKey, wrappedKey: SecureData)? {
        let lines = file.split(separator: "\n")
        return clientKeyV2(lines: lines)
    }

    static func clientKeyV2(lines: [Substring]) -> (key: OpenVPN.StaticKey, wrappedKey: SecureData)? {
        var isHead = true
        var base64Lines: [Substring] = []

        for line in lines {
            if isHead {
                guard !line.hasPrefix("#") else {
                    continue
                }
                guard !line.isEmpty else {
                    continue
                }
                guard line == Self.clientV2FileHead else {
                    return nil
                }
                isHead = false
                continue
            }

            guard let first = line.first else {
                continue
            }
            if first == "-" {
                guard line == Self.clientV2FileFoot else {
                    return nil
                }
                break
            }
            base64Lines.append(line)
        }

        let base64 = String(base64Lines.joined())
        guard let keyData = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              keyData.count > 256 else {
            return nil
        }

        let staticKey = OpenVPN.StaticKey(
            data: keyData.subdata(in: 0..<256),
            direction: .client
        )
        let wrappedKey = SecureData(keyData.subdata(in: 256..<keyData.count))
        return (staticKey, wrappedKey)
    }
}
