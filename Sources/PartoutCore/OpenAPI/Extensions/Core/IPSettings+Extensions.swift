// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension IPSettings {
    public init(subnets: [Subnet]) {
        self.init(subnets: subnets, includedRoutes: [], excludedRoutes: [])
    }

    public init(subnet: Subnet?) {
        self.init(subnets: subnet.map { [$0] } ?? [])
    }

    public func with(subnet: Subnet?) -> Self {
        Self(
            subnets: subnet.map { [$0] } ?? [],
            includedRoutes: includedRoutes,
            excludedRoutes: excludedRoutes
        )
    }

    public mutating func include(_ route: Route) {
        self = including(routes: includedRoutes + [route])
    }

    public mutating func removeIncluded(at offsets: IndexSet) {
        self = including(routes: includedRoutes.removing(at: offsets))
    }

    public mutating func exclude(_ route: Route) {
        self = excluding(routes: excludedRoutes + [route])
    }

    public mutating func removeExcluded(at offsets: IndexSet) {
        self = excluding(routes: excludedRoutes.removing(at: offsets))
    }

    public func including(routes: [Route]) -> Self {
        subnets.forEach { subnet in
            precondition(routes.allSatisfy {
                $0.destination == nil || $0.destination?.address.family == subnet.address.family
            })
        }
        return Self(subnets: subnets, includedRoutes: routes, excludedRoutes: excludedRoutes)
    }

    public func excluding(routes: [Route]) -> Self {
        subnets.forEach { subnet in
            precondition(routes.allSatisfy {
                $0.destination == nil || $0.destination?.address.family == subnet.address.family
            })
        }
        return Self(subnets: subnets, includedRoutes: includedRoutes, excludedRoutes: routes)
    }

    public var includesDefaultRoute: Bool {
        includedRoutes.contains(where: \.isDefault)
    }

    public var defaultRoute: Route? {
        includedRoutes.first(where: \.isDefault)
    }

    public var nilIfEmpty: Self? {
        guard !subnets.isEmpty || !includedRoutes.isEmpty || !excludedRoutes.isEmpty else {
            return nil
        }
        return self
    }
}

private extension Array {
    func removing(at offsets: IndexSet) -> Self {
        var copy = self
        offsets.forEach {
            copy.remove(at: $0)
        }
        return copy
    }
}

extension IPSettings {
    enum CodingKeys: String, CodingKey {
        case subnets
        case includedRoutes
        case excludedRoutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let subnets = try container.decodeIfPresent([Subnet].self, forKey: .subnets) ?? []
        let includedRoutes = try container.decodeIfPresent([Route].self, forKey: .includedRoutes) ?? []
        let excludedRoutes = try container.decodeIfPresent([Route].self, forKey: .excludedRoutes) ?? []
        self.init(subnets: subnets, includedRoutes: includedRoutes, excludedRoutes: excludedRoutes)
    }
}

extension IPSettings: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        let subnetDescriptions = subnets.map {
            $0.debugDescription(withSensitiveData: withSensitiveData)
        }
        return "addrs \(subnetDescriptions), includedRoutes=\(includedRoutes.map(\.debugDescription)), excludedRoutes=\(excludedRoutes.map(\.debugDescription))"
    }
}
