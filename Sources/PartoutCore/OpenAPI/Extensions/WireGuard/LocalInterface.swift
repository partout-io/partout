// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuard.LocalInterface: BuildableType {
    public func builder() -> Builder {
        var copy = Builder(privateKey: privateKey.rawValue)
        copy.addresses = addresses.map(\.rawValue)
        copy.dns = dns?.builder()
        copy.mtu = mtu
        return copy
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
                addresses: validAddresses,
                dns: try dns?.build(),
                mtu: mtu,
                privateKey: validPrivateKey
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
