// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuard {

    /// The parameters of the local interface.
    public struct LocalInterface: BuildableType, Hashable, Codable, Sendable {

        /// The local private key.
        public let privateKey: Key

        /// The local addresses.
        public let addresses: [Subnet]

        /// The optional DNS settings.
        public let dns: DNSModule?

        /// The optional MTU.
        public let mtu: UInt16?

        public init(privateKey: Key, addresses: [Subnet], dns: DNSModule?, mtu: UInt16?) {
            self.privateKey = privateKey
            self.addresses = addresses
            self.dns = dns
            self.mtu = mtu
        }

        public func builder() -> Builder {
            var copy = Builder(privateKey: privateKey.rawValue)
            copy.addresses = addresses.map(\.rawValue)
            copy.dns = dns?.builder()
            copy.mtu = mtu
            return copy
        }
    }
}

extension WireGuard.LocalInterface {
    public struct Builder: BuilderType, Hashable, Sendable {
        public var privateKey: String

        public var addresses: [String]

        public var dns: DNSModule.Builder?

        public var mtu: UInt16?

        public init(privateKey: String) {
            self.privateKey = privateKey
            dns = nil
            addresses = []
        }

        public init(keyGenerator: WireGuardKeyGenerator) {
            privateKey = keyGenerator.newPrivateKey()
            dns = nil
            addresses = []
        }

        public func build() throws -> WireGuard.LocalInterface {
            guard let validPrivateKey = WireGuard.Key(rawValue: privateKey) else {
                throw PartoutError.invalidField(.WireGuard.privateKey)
            }
            let validAddresses = try addresses.map {
                guard let addr = Subnet(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.addresses)
                }
                return addr
            }
            return WireGuard.LocalInterface(
                privateKey: validPrivateKey,
                addresses: validAddresses,
                dns: try dns?.build(),
                mtu: mtu
            )
        }
    }
}

extension PartoutError.ModuleField {
    public enum WireGuard {
        private static let root = "WireGuard"
        public static let privateKey = PartoutError.ModuleField("\(root).privateKey")
        public static let addresses = PartoutError.ModuleField("\(root).addresses")
    }
}
