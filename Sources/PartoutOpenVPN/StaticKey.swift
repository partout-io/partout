// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {

    /// Represents an OpenVPN static key file (as generated with --genkey)
    public struct StaticKey: Hashable, Codable, Sendable {
        enum CodingKeys: String, CodingKey {
            case secureData = "data"

            case direction = "dir"
        }

        /// The key-direction field, usually 0 on servers and 1 on clients.
        public enum Direction: Int, Hashable, Codable, Sendable {

            /// Conventional server direction (implicit for tls-crypt).
            case server = 0

            /// Conventional client direction (implicit for tls-crypt).
            case client = 1
        }

        private static let contentLength = 256 // 2048-bit

        private static let keyCount = 4

        private static let keyLength = StaticKey.contentLength / StaticKey.keyCount

        private static let fileHead = "-----BEGIN OpenVPN Static key V1-----"

        private static let fileFoot = "-----END OpenVPN Static key V1-----"

        private static let nonHexCharset = CharacterSet(charactersIn: "0123456789abcdefABCDEF").inverted

        public let secureData: SecureData

        public let direction: Direction?

        /// Returns the encryption key.
        ///
        /// - Precondition: `direction` must be non-nil.
        /// - Seealso: `Configuration.Builder.tlsWrap`
        public var cipherEncryptKey: SecureData {
            guard let direction else {
                fatalError("Direction not set")
            }
            switch direction {
            case .server:
                return key(at: 0)

            case .client:
                return key(at: 2)
            }
        }

        /// Returns the decryption key.
        ///
        /// - Precondition: `direction` must be non-nil.
        /// - Seealso: `Configuration.Builder.tlsWrap`
        public var cipherDecryptKey: SecureData {
            guard let direction else {
                fatalError("Direction not set")
            }
            switch direction {
            case .server:
                return key(at: 2)

            case .client:
                return key(at: 0)
            }
        }

        /// Returns the HMAC sending key.
        ///
        /// - Seealso: `Configuration.Builder.tlsWrap`
        public var hmacSendKey: SecureData {
            guard let direction else {
                return key(at: 1)
            }
            switch direction {
            case .server:
                return key(at: 1)

            case .client:
                return key(at: 3)
            }
        }

        /// Returns the HMAC receiving key.
        ///
        /// - Seealso: `Configuration.Builder.tlsWrap`
        public var hmacReceiveKey: SecureData {
            guard let direction else {
                return key(at: 1)
            }
            switch direction {
            case .server:
                return key(at: 3)

            case .client:
                return key(at: 1)
            }
        }

        /**
         Initializes with data and direction.

         - Parameter data: The key data.
         - Parameter direction: The key direction, or bidirectional if nil. For tls-crypt behavior, must not be nil.
         */
        public init(data: Data, direction: Direction?) {
            precondition(data.count == StaticKey.contentLength)
            secureData = SecureData(data)
            self.direction = direction
        }

        /**
         Initializes with file content and direction.

         - Parameter file: The text file containing the key.
         - Parameter direction: The key direction, or bidirectional if nil.
         */
        public init?(file: String, direction: Direction?) {
            let lines = file.split(separator: "\n")
            self.init(lines: lines, direction: direction)
        }

        public init?(lines: [Substring], direction: Direction?) {
            var isHead = true
            var hexLines: [Substring] = []

            for l in lines {
                if isHead {
                    guard !l.hasPrefix("#") else {
                        continue
                    }
                    guard l == StaticKey.fileHead else {
                        return nil
                    }
                    isHead = false
                    continue
                }
                guard let first = l.first else {
                    return nil
                }
                if first == "-" {
                    guard l == StaticKey.fileFoot else {
                        return nil
                    }
                    break
                }
                hexLines.append(l)
            }

            let hex = String(hexLines.joined())
            guard hex.count == 2 * StaticKey.contentLength else {
                return nil
            }
            if hex.rangeOfCharacter(from: StaticKey.nonHexCharset) != nil {
                return nil
            }
            let data = Data(hex: hex)

            self.init(data: data, direction: direction)
        }

        /**
         Initializes as bidirectional.

         - Parameter data: The key data.
         */
        public init(biData data: Data) {
            self.init(data: data, direction: nil)
        }

        private func key(at: Int) -> SecureData {
            let size = secureData.count / StaticKey.keyCount // 64 bytes each
            assert(size == StaticKey.keyLength)
            return secureData.withOffset(at * size, count: size)
        }

        public var hexString: String {
            secureData.toHex()
        }

        // MARK: Equatable

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.secureData == rhs.secureData
        }
    }
}
