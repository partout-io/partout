// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore

extension WireGuard {

    /// The parameters of the remote interface.
    public struct RemoteInterface: BuildableType, Hashable, Codable, Sendable {

        /// The endpoint public key.
        public let publicKey: Key

        /// The optional endpoint pre-shared key.
        public let preSharedKey: Key?

        /// The optional endpoint.
        public let endpoint: Endpoint?

        /// The list of allowed subnets.
        public let allowedIPs: [Subnet]

        /// The keep-alive interval in seconds.
        public let keepAlive: UInt16?

        public init(
            publicKey: Key,
            preSharedKey: Key?,
            endpoint: Endpoint?,
            allowedIPs: [Subnet],
            keepAlive: UInt16?
        ) {
            self.publicKey = publicKey
            self.preSharedKey = preSharedKey
            self.endpoint = endpoint
            self.allowedIPs = allowedIPs
            self.keepAlive = keepAlive
        }

        public func builder() -> Builder {
            var copy = Builder(publicKey: publicKey.rawValue)
            copy.preSharedKey = preSharedKey?.rawValue
            copy.endpoint = endpoint?.rawValue
            copy.allowedIPs = allowedIPs.map(\.rawValue)
            copy.keepAlive = keepAlive
            return copy
        }
    }
}

extension WireGuard.RemoteInterface {
    public struct Builder: BuilderType, Hashable {
        public let publicKey: String

        public var preSharedKey: String?

        public var endpoint: String?

        public var allowedIPs: [String]

        public var keepAlive: UInt16?

        public init(publicKey: String) {
            self.publicKey = publicKey
            allowedIPs = []
        }

        public func tryBuild() throws -> WireGuard.RemoteInterface {
            guard let validPublicKey = WireGuard.Key(rawValue: publicKey) else {
                throw PartoutError.invalidFields(["publicKey": publicKey])
            }
            let validPreSharedKey = try preSharedKey.map {
                guard let key = WireGuard.Key(rawValue: $0) else {
                    throw PartoutError.invalidFields(["preSharedKey": $0])
                }
                return key
            }
            let validEndpoint = try endpoint.map {
                guard let ep = Endpoint(rawValue: $0) else {
                    throw PartoutError.invalidFields(["endpoint": $0])
                }
                return ep
            }
            let validAllowedIPs = try allowedIPs.map {
                guard let addr = Subnet(rawValue: $0) else {
                    throw PartoutError.invalidFields(["allowedIPs": $0])
                }
                return addr
            }
            return WireGuard.RemoteInterface(
                publicKey: validPublicKey,
                preSharedKey: validPreSharedKey,
                endpoint: validEndpoint,
                allowedIPs: validAllowedIPs,
                keepAlive: keepAlive
            )
        }
    }
}

// MARK: - Shortcuts

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

// MARK: - Helpers

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
