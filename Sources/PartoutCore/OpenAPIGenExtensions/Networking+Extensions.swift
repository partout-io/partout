// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutPortable_C

extension Address: RawRepresentable {
    public var rawValue: String {
        switch self {
        case .ip(let string, _):
            return string
        case .hostname(let string):
            return string
        }
    }

    public var isIPAddress: Bool {
        guard case .ip = self else {
            return false
        }
        return true
    }

    public var family: Family? {
        switch self {
        case .ip(_, let family):
            return family
        default:
            return nil
        }
    }

    public init?(rawValue: String) {
        let baseValue = rawValue.trimmingCharacters(in: .whitespaces)
        guard !baseValue.isEmpty else {
            return nil
        }
        switch baseValue.addressFamily {
        case .v4:
            self = .ip(baseValue, .v4)
        case .v6:
            self = .ip(baseValue, .v6)
        default:
            guard baseValue != PartoutLogger.redactedValue else {
                return nil
            }
            self = .hostname(baseValue)
        }
    }

    public init?(data: Data) {
        switch data.count {
        case 4:
            let comps = data.map {
                UInt8($0).description
            }
            self = .ip(comps.joined(separator: "."), .v4)
        case 16:
            let comps = data.map {
                String(format: "%.02x", $0)
            }
            let quadComps = comps.joined().components(withLength: 4)
            self = .ip(quadComps.joined(separator: ":"), .v6)
        default:
            return nil
        }
    }
}

private extension String {
    func components(withLength length: Int) -> [String] {
        stride(from: 0, to: count, by: length)
            .map {
                let start = index(startIndex, offsetBy: $0)
                let end = index(start, offsetBy: length, limitedBy: endIndex) ?? endIndex
                return String(self[start..<end])
            }
    }
}

extension Address: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension Address {
    public func network(with ipv4Mask: String) -> Address? {
        assert(family == .v4)
        let dstLength = Int(INET_ADDRSTRLEN)
        var dst: [CChar] = Array(repeating: .zero, count: dstLength)
        let result = rawValue.utf8CString.withUnsafeBytes { addrPtr in
            ipv4Mask.utf8CString.withUnsafeBytes { netmaskPtr in
                dst.withUnsafeMutableBytes { dstPtr in
                    pp_addr_network_v4(
                        dstPtr.baseAddress,
                        dstLength,
                        addrPtr.baseAddress,
                        netmaskPtr.baseAddress
                    )
                }
            }
        }
        guard result != 0 else {
            return nil
        }
        return Address(rawValue: dst.string)
    }

    public func network(with ipv6PrefixLength: Int) -> Address? {
        let dstLength = Int(INET6_ADDRSTRLEN)
        var dst: [CChar] = Array(repeating: .zero, count: dstLength)
        let result = rawValue.utf8CString.withUnsafeBytes { addrPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                pp_addr_network_v6(
                    dstPtr.baseAddress,
                    dstLength,
                    addrPtr.baseAddress,
                    Int32(ipv6PrefixLength)
                )
            }
        }
        guard result != 0 else {
            return nil
        }
        return Address(rawValue: dst.string)
    }
}

private extension String {
    var addressFamily: Address.Family? {
        let cFamily = pp_addr_family_of(cString(using: .utf8))
        switch cFamily {
        case PPAddrFamilyV4:
            return .v4
        case PPAddrFamilyV6:
            return .v6
        default:
            return nil
        }
    }
}

extension Address: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? rawValue : PartoutLogger.redactedValue
    }
}

extension IPSocketType {
    public var plainType: SocketType {
        switch self {
        case .udp, .udp4, .udp6:
            return .udp
        case .tcp, .tcp4, .tcp6:
            return .tcp
        }
    }
}

extension EndpointProtocol {
    public init(_ socketType: IPSocketType, _ port: UInt16) {
        self.init(socketType: socketType, port: port)
    }
}

extension EndpointProtocol: RawRepresentable {
    public init?(rawValue: String) {
        let components = rawValue.components(separatedBy: ":")
        guard components.count == 2 else {
            return nil
        }
        guard let socketType = IPSocketType(rawValue: components[0]) else {
            return nil
        }
        guard let port = UInt16(components[1]) else {
            return nil
        }
        self.init(socketType, port)
    }

    public var rawValue: String {
        "\(socketType.rawValue):\(port)"
    }
}

extension EndpointProtocol: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension EndpointProtocol: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let proto = EndpointProtocol(rawValue: rawValue) else {
            throw PartoutError(.decoding)
        }
        self.init(proto.socketType, proto.port)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Endpoint {
    public init(_ rawAddress: String, _ port: UInt16) throws {
        guard let address = Address(rawValue: rawAddress) else {
            throw PartoutError(.invalidValue)
        }
        self.init(address, port)
    }

    public init(_ address: Address, _ port: UInt16) {
        self.init(address: address, port: port)
    }
}

extension Endpoint: RawRepresentable {
    public var rawValue: String {
        "\(address):\(port)"
    }

    public init?(rawValue: String) {
        guard let indexOfSeparator = rawValue.lastIndex(of: ":") else {
            return nil
        }
        guard indexOfSeparator != rawValue.endIndex else {
            return nil
        }
        let rawAddress = rawValue[rawValue.startIndex..<indexOfSeparator]
        let rawPort = rawValue[rawValue.index(indexOfSeparator, offsetBy: 1)..<rawValue.endIndex]
        guard let port = UInt16(rawPort) else {
            return nil
        }
        try? self.init(String(rawAddress), port)
    }
}

extension Endpoint: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension Endpoint: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        let addressDescription = address.debugDescription(withSensitiveData: withSensitiveData)
        return "\(addressDescription):\(port)"
    }
}

extension ExtendedEndpoint {
    private static var rx: Regex<(Substring, Substring, Substring, Substring)> {
        let pattern = "^([^\\s]+):(UDP[46]?|TCP[46]?):(\\d+)$"
        do {
            return try Regex<(Substring, Substring, Substring, Substring)>(pattern)
        } catch {
            fatalError("Invalid pattern: \(pattern), \(error)")
        }
    }

    public init(_ rawAddress: String, _ proto: EndpointProtocol) throws {
        guard let address = Address(rawValue: rawAddress) else {
            throw PartoutError(.invalidValue)
        }
        self.init(address, proto)
    }

    public init(_ address: Address, _ proto: EndpointProtocol) {
        self.init(address: address, proto: proto)
    }

    public var isIPv4: Bool {
        address.rawValue.withCString {
            pp_addr_family_of($0) == PPAddrFamilyV4
        }
    }

    public var isIPv6: Bool {
        address.rawValue.withCString {
            pp_addr_family_of($0) == PPAddrFamilyV6
        }
    }

    public var isHostname: Bool {
        !isIPv4 && !isIPv6
    }

    public var plainSocketType: SocketType {
        proto.socketType.plainType
    }
}

extension ExtendedEndpoint: RawRepresentable {
    public init?(rawValue: String) {
        do {
            guard let match = try Self.rx.wholeMatch(in: rawValue) else {
                return nil
            }
            let rawAddress = String(match.1)
            guard let socketType = IPSocketType(rawValue: String(match.2)) else {
                return nil
            }
            guard let port = UInt16(match.3) else {
                return nil
            }
            try self.init(rawAddress, EndpointProtocol(socketType, port))
        } catch {
            print(error)
            return nil
        }
    }

    public var rawValue: String {
        "\(address):\(proto.socketType.rawValue):\(proto.port)"
    }
}

extension ExtendedEndpoint: CustomStringConvertible {
    public var description: String {
        "\(address):\(proto.rawValue)"
    }
}

extension ExtendedEndpoint: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        let addressDescription = address.debugDescription(withSensitiveData: withSensitiveData)
        return "\(addressDescription):\(proto.rawValue)"
    }
}

extension Subnet {
    public var ipv4Mask: String {
        guard case .ip(_, let family) = address else {
            preconditionFailure()
        }
        precondition(family == .v4)
        return prefixLength.asNetworkMask
    }

    public init(_ rawAddress: String, _ prefixLength: Int) throws {
        guard let address = Address(rawValue: rawAddress) else {
            throw PartoutError(.invalidValue)
        }
        switch address.family {
        case .v4:
            guard prefixLength <= 32 else {
                throw PartoutError(.invalidValue)
            }
        case .v6:
            guard prefixLength <= 128 else {
                throw PartoutError(.invalidValue)
            }
        default:
            throw PartoutError(.invalidValue)
        }
        guard let subnet = Subnet(address, prefixLength) else {
            throw PartoutError(.invalidValue)
        }
        self = subnet
    }

    public init(_ rawAddress: String, _ ipv4Mask: String) throws {
        try self.init(rawAddress, ipv4Mask.asPrefixLength)
    }

    public init?(_ address: Address) {
        switch address.family {
        case .v4:
            self.init(address, 32)
        case .v6:
            self.init(address, 128)
        default:
            preconditionFailure("Missing address family")
        }
    }

    public init?(_ address: Address, _ prefixLength: Int) {
        guard case .ip(_, let family) = address else {
            preconditionFailure()
        }
        let maxPrefixLength = family == .v6 ? 128 : 32
        guard prefixLength >= 0 && prefixLength <= maxPrefixLength else {
            return nil
        }
        self.init(address: address, prefixLength: prefixLength)
    }
}

extension Subnet: RawRepresentable {
    public var rawValue: String {
        "\(address)/\(prefixLength)"
    }

    public init?(rawValue: String) {
        let comps = rawValue.components(separatedBy: "/")
        switch comps.count {
        case 1:
            guard let addr = Address(rawValue: comps[0]), addr.isIPAddress else { return nil }
            self.init(addr)
        case 2:
            guard let addr = Address(rawValue: comps[0]), addr.isIPAddress else { return nil }
            guard let prefixLength = Int(comps[1]) else { return nil }
            self.init(addr, prefixLength)
        default:
            return nil
        }
    }
}

extension Subnet: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension Subnet: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        let addressDescription = address.debugDescription(withSensitiveData: withSensitiveData)
        return "\(addressDescription)/\(prefixLength)"
    }
}

private extension String {
    var asPrefixLength: Int {
        var n = UInt32()
        inet_pton(AF_INET, self, &n)
        n = pp_swap_big32_to_host(n)
        var i = 0
        while n > 0 {
            if n & 1 == 1 {
                i += 1
            }
            n >>= 1
        }
        return i
    }
}

private extension Int {
    var asNetworkMask: String {
        guard self > 0 else {
            return "0.0.0.0"
        }
        let mask = (0xffffffff << (32 - self)) & 0xffffffff
        return "\(mask >> 24).\((mask >> 16) & 0xff).\((mask >> 8) & 0xff).\(mask & 0xff)"
    }
}

extension Route {
    public var isDefault: Bool {
        destination == nil
    }

    public init(_ destination: Subnet?, _ gateway: Address?) {
        self.init(destination: destination, gateway: gateway)
    }

    public init(defaultWithGateway gateway: Address?) {
        self.init(destination: nil, gateway: gateway)
    }
}

extension Route: CustomDebugStringConvertible {
    public var debugDescription: String {
        "{\(destination?.description ?? "default") \(gateway?.description ?? "*")}"
    }
}

extension IPSettings {
    public init(subnets: [Subnet]) {
        self.init(subnets: subnets, includedRoutes: [], excludedRoutes: [])
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

    public var nilIfEmpty: Self? {
        guard !subnets.isEmpty || !includedRoutes.isEmpty || !excludedRoutes.isEmpty else {
            return nil
        }
        return self
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

extension ExtendedEndpoint {
    var socketProto: pp_socket_proto {
        switch plainSocketType {
        case .udp:
            return PPSocketProtoUDP
        case .tcp:
            return PPSocketProtoTCP
        }
    }
}
