// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// IP settings and routes.
public struct IPSettings: Hashable, Codable, Sendable {
    /// The subnets.
    public private(set) var subnets: [Subnet]

    /// The subnet.
    @available(*, deprecated, message: "For temporary decoding backward-compatibility")
    private var legacySingleSubnet: Subnet?

    /// The included routes.
    public private(set) var includedRoutes: [Route]

    /// The excluded routes.
    public private(set) var excludedRoutes: [Route]

    public init(subnets: [Subnet]) {
        self.subnets = subnets
        includedRoutes = []
        excludedRoutes = []
    }

    public init(subnet: Subnet?) {
        self.init(subnets: subnet.map { [$0] } ?? [])
    }

    public func with(subnet: Subnet?) -> Self {
        var copy = self
        copy.subnets = subnet.map { [$0] } ?? []
        return copy
    }

    public mutating func include(_ route: Route) {
        includedRoutes.append(route)
    }

    public mutating func removeIncluded(at offsets: IndexSet) {
        offsets.forEach {
            includedRoutes.remove(at: $0)
        }
    }

    public mutating func exclude(_ route: Route) {
        excludedRoutes.append(route)
    }

    public mutating func removeExcluded(at offsets: IndexSet) {
        offsets.forEach {
            excludedRoutes.remove(at: $0)
        }
    }

    public func including(routes: [Route]) -> Self {
        subnets.forEach { subnet in
            precondition(routes.allSatisfy {
                $0.destination == nil || $0.destination?.address.family == subnet.address.family
            })
        }
        var copy = self
        copy.includedRoutes = routes
        return copy
    }

    public func excluding(routes: [Route]) -> Self {
        subnets.forEach { subnet in
            precondition(routes.allSatisfy {
                $0.destination == nil || $0.destination?.address.family == subnet.address.family
            })
        }
        var copy = self
        copy.excludedRoutes = routes
        return copy
    }

    public var includesDefaultRoute: Bool {
        includedRoutes.contains(where: \.isDefault)
    }

    public var defaultRoute: Route? {
        includedRoutes.first(where: \.isDefault)
    }
}

extension IPSettings {
    public var nilIfEmpty: Self? {
        guard !subnets.isEmpty || !includedRoutes.isEmpty || !excludedRoutes.isEmpty else {
            return nil
        }
        return self
    }
}

// MARK: - Encodable

extension IPSettings {
    enum CodingKeys: String, CodingKey {
        case subnets

        case legacySingleSubnet = "subnet"

        case includedRoutes

        case excludedRoutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            subnets = try container.decodeIfPresent([Subnet].self, forKey: .subnets) ?? []
        } catch {
            let singleSubnet = try container.decodeIfPresent(Subnet.self, forKey: .legacySingleSubnet)
            subnets = singleSubnet.map { [$0] } ?? []
        }
        includedRoutes = try container.decodeIfPresent([Route].self, forKey: .includedRoutes) ?? []
        excludedRoutes = try container.decodeIfPresent([Route].self, forKey: .excludedRoutes) ?? []
    }
}

// MARK: - SensitiveDebugStringConvertible

extension IPSettings: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        let subnetDescriptions = subnets.map {
            $0.debugDescription(withSensitiveData: withSensitiveData)
        }
        return "addrs \(subnetDescriptions), includedRoutes=\(includedRoutes.map(\.debugDescription)), excludedRoutes=\(excludedRoutes.map(\.debugDescription))"
    }
}
