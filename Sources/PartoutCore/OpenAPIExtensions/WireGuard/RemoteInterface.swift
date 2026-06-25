// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuard.RemoteInterface: BuildableType {
    public func builder() -> Builder {
        var copy = Builder(publicKey: publicKey.rawValue)
        copy.preSharedKey = preSharedKey?.rawValue
        copy.endpoint = endpoint?.rawValue
        copy.allowedIPs = allowedIPs.map(\.rawValue)
        copy.keepAlive = keepAlive
        return copy
    }
}

extension WireGuard.RemoteInterface {
    public struct Builder: BuilderType, Hashable, Sendable {
        public let publicKey: String
        public var preSharedKey: String?
        public var endpoint: String?
        public var allowedIPs: [String]
        public var keepAlive: UInt16?

        public init(publicKey: String) {
            self.publicKey = publicKey
            allowedIPs = []
        }

        public func build() throws -> WireGuard.RemoteInterface {
            guard let validPublicKey = WireGuard.Key(rawValue: publicKey) else {
                throw PartoutError.invalidField(.WireGuard.publicKey)
            }
            let validPreSharedKey: WireGuard.Key? = try preSharedKey.flatMap {
                guard !$0.isEmpty else { return nil }
                guard let key = WireGuard.Key(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.preSharedKey)
                }
                return key
            }
            let validEndpoint = try endpoint.map {
                guard let ep = Endpoint(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.endpoint)
                }
                return ep
            }
            let validAllowedIPs = try allowedIPs.map {
                guard let addr = Subnet(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.allowedIPs)
                }
                return addr
            }
            return WireGuard.RemoteInterface(
                allowedIPs: validAllowedIPs,
                endpoint: validEndpoint,
                keepAlive: keepAlive,
                preSharedKey: validPreSharedKey,
                publicKey: validPublicKey
            )
        }
    }
}

extension WireGuard.RemoteInterface.Builder {
    public mutating func addAllowedIP(_ allowedIP: String) {
        allowedIPs.append(allowedIP)
    }

    public mutating func removeAllowedIP(_ allowedIP: String) {
        allowedIPs.removeAll {
            $0 == allowedIP
        }
    }

    public mutating func addDefaultGatewayIPv4() {
        allowedIPs.append(Subnet.defaultGateway4.rawValue)
    }

    public mutating func addDefaultGatewayIPv6() {
        allowedIPs.append(Subnet.defaultGateway6.rawValue)
    }

    public mutating func removeDefaultGatewayIPv4() {
        allowedIPs.removeAll {
            $0 == Subnet.defaultGateway4.rawValue
        }
    }

    public mutating func removeDefaultGatewayIPv6() {
        allowedIPs.removeAll {
            $0 == Subnet.defaultGateway6.rawValue
        }
    }

    public mutating func removeDefaultGateways() {
        allowedIPs.removeAll {
            $0 == Subnet.defaultGateway4.rawValue || $0 == Subnet.defaultGateway6.rawValue
        }
    }
}

private extension Subnet {
    static let defaultGateway4: Subnet = {
        do {
            return try Subnet("0.0.0.0", 0)
        } catch {
            fatalError("Cannot build: \(error)")
        }
    }()

    static let defaultGateway6: Subnet = {
        do {
            return try Subnet("::/0", 0)
        } catch {
            fatalError("Cannot build: \(error)")
        }
    }()
}

extension PartoutError.ModuleField.WireGuard {
    public static let publicKey = PartoutError.ModuleField("WireGuard.publicKey")
    public static let preSharedKey = PartoutError.ModuleField("WireGuard.preSharedKey")
    public static let endpoint = PartoutError.ModuleField("WireGuard.endpoint")
    public static let allowedIPs = PartoutError.ModuleField("WireGuard.allowedIPs")
}
