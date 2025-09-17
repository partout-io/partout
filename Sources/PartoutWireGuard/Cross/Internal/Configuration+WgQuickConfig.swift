// SPDX-License-Identifier: MIT
// Copyright © 2018-2021 WireGuard LLC. All Rights Reserved.

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension WireGuard.Configuration {

    enum ParserState {
        case inInterfaceSection
        case inPeerSection
        case notInASection
    }

    init(fromWgQuickConfig wgQuickConfig: String, called name: String? = nil) throws {
        var interfaceConfiguration: WireGuard.LocalInterface?
        var peerConfigurations = [WireGuard.RemoteInterface]()

        let lines = wgQuickConfig.split { $0.isNewline }

        var parserState = ParserState.notInASection
        var attributes = [String: String]()

        for (lineIndex, line) in lines.enumerated() {
            var trimmedLine: String
            if let commentRange = line.range(of: "#") {
                trimmedLine = String(line[..<commentRange.lowerBound])
            } else {
                trimmedLine = String(line)
            }

            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            if !trimmedLine.isEmpty {
                if let equalsIndex = trimmedLine.firstIndex(of: "=") {
                    // Line contains an attribute
                    let keyWithCase = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = keyWithCase.lowercased()
                    let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let keysWithMultipleEntriesAllowed: Set<String> = ["address", "allowedips", "dns"]
                    if let presentValue = attributes[key] {
                        if keysWithMultipleEntriesAllowed.contains(key) {
                            attributes[key] = presentValue + "," + value
                        } else {
                            throw WireGuardParseError.multipleEntriesForKey(keyWithCase)
                        }
                    } else {
                        attributes[key] = value
                    }
                    let interfaceSectionKeys: Set<String> = ["privatekey", "listenport", "address", "dns", "dnsoverhttpsurl", "dnsovertlsservername", "mtu"]
                    let peerSectionKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"]
                    if parserState == .inInterfaceSection {
                        guard interfaceSectionKeys.contains(key) else {
                            throw WireGuardParseError.interfaceHasUnrecognizedKey(keyWithCase)
                        }
                    } else if parserState == .inPeerSection {
                        guard peerSectionKeys.contains(key) else {
                            throw WireGuardParseError.peerHasUnrecognizedKey(keyWithCase)
                        }
                    }
                } else if lowercasedLine != "[interface]" && lowercasedLine != "[peer]" {
                    throw WireGuardParseError.invalidLine(line)
                }
            }

            let isLastLine = lineIndex == lines.count - 1

            if isLastLine || lowercasedLine == "[interface]" || lowercasedLine == "[peer]" {
                // Previous section has ended; process the attributes collected so far
                if parserState == .inInterfaceSection {
                    let interface = try Self.collate(interfaceAttributes: attributes)
                    guard interfaceConfiguration == nil else { throw WireGuardParseError.multipleInterfaces }
                    interfaceConfiguration = interface
                } else if parserState == .inPeerSection {
                    let peer = try Self.collate(peerAttributes: attributes)
                    peerConfigurations.append(peer)
                }
            }

            if lowercasedLine == "[interface]" {
                parserState = .inInterfaceSection
                attributes.removeAll()
            } else if lowercasedLine == "[peer]" {
                parserState = .inPeerSection
                attributes.removeAll()
            }
        }

        let peerPublicKeysArray = peerConfigurations.map(\.publicKey)
        let peerPublicKeysSet = Set(peerPublicKeysArray)
        if peerPublicKeysArray.count != peerPublicKeysSet.count {
            throw WireGuardParseError.multiplePeersWithSamePublicKey
        }

        guard let interfaceConfiguration else {
            throw WireGuardParseError.noInterface
        }
        self.init(interface: interfaceConfiguration, peers: peerConfigurations)
    }

    func asWgQuickConfig() -> String {
        var output = "[Interface]\n"
        output.append("PrivateKey = \(interface.privateKey.rawValue)\n")
        // TODO: #93, listenPort not implemented
//        if let listenPort = interface.listenPort {
//            output.append("ListenPort = \(listenPort)\n")
//        }
        if !interface.addresses.isEmpty {
            let addressString = interface.addresses.map(\.rawValue).joined(separator: ", ")
            output.append("Address = \(addressString)\n")
        }
        if let dns = interface.dns,
           dns.searchDomains?.isEmpty != true || !dns.servers.isEmpty {
            var dnsLine = dns.servers.map(\.rawValue)
            dnsLine.append(contentsOf: dns.searchDomains?.map(\.rawValue) ?? [])
            let dnsString = dnsLine.joined(separator: ", ")
            output.append("DNS = \(dnsString)\n")
        }
        if let mtu = interface.mtu {
            output.append("MTU = \(mtu)\n")
        }

        for peer in peers {
            output.append("\n[Peer]\n")
            output.append("PublicKey = \(peer.publicKey.rawValue)\n")
            if let preSharedKey = peer.preSharedKey?.rawValue {
                output.append("PresharedKey = \(preSharedKey)\n")
            }
            if !peer.allowedIPs.isEmpty {
                let allowedIPsString = peer.allowedIPs.map(\.rawValue).joined(separator: ", ")
                output.append("AllowedIPs = \(allowedIPsString)\n")
            }
            if let endpoint = peer.endpoint {
                output.append("Endpoint = \(endpoint.rawValue)\n")
            }
            if let persistentKeepAlive = peer.keepAlive {
                output.append("PersistentKeepalive = \(persistentKeepAlive)\n")
            }
        }

        return output
    }

    private static func collate(interfaceAttributes attributes: [String: String]) throws -> WireGuard.LocalInterface {
        guard let privateKeyString = attributes["privatekey"] else {
            throw WireGuardParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw WireGuardParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }
        var interface = WireGuard.LocalInterface.Builder(privateKey: privateKey.base64Key)
        // TODO: #93, listenPort not implemented
//        if let listenPortString = attributes["listenport"] {
//            guard let listenPort = UInt16(listenPortString) else {
//                throw WireGuardParseError.interfaceHasInvalidListenPort(listenPortString)
//            }
//            interface.listenPort = listenPort
//        }
        if let addressesString = attributes["address"] {
            var addresses = [Address]()
            for addressString in addressesString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let address = Address(rawValue: addressString) else {
                    throw WireGuardParseError.interfaceHasInvalidAddress(addressString)
                }
                addresses.append(address)
            }
            interface.addresses = addresses.map(\.rawValue)
        }
        if let dnsString = attributes["dns"] {
            var dnsServers = [Address]()
            var dnsSearch = [String]()
            for line in dnsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let addr = Address(rawValue: line) else { continue }
                if addr.isIPAddress {
                    dnsServers.append(addr)
                } else {
                    dnsSearch.append(addr.rawValue)
                }
            }
            interface.dns.servers = dnsServers.map(\.rawValue)
            interface.dns.searchDomains = dnsSearch
        }
        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw WireGuardParseError.interfaceHasInvalidMTU(mtuString)
            }
            interface.mtu = mtu
        }
        return try interface.tryBuild()
    }

    private static func collate(peerAttributes attributes: [String: String]) throws -> WireGuard.RemoteInterface {
        guard let publicKeyString = attributes["publickey"] else {
            throw WireGuardParseError.peerHasNoPublicKey
        }
        guard let publicKey = PublicKey(base64Key: publicKeyString) else {
            throw WireGuardParseError.peerHasInvalidPublicKey(publicKeyString)
        }
        var peer = WireGuard.RemoteInterface.Builder(publicKey: publicKey.base64Key)
        if let preSharedKeyString = attributes["presharedkey"] {
            guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
                throw WireGuardParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            peer.preSharedKey = preSharedKey.base64Key
        }
        if let allowedIPsString = attributes["allowedips"] {
            var allowedIPs = [Subnet]()
            for allowedIPString in allowedIPsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let allowedIP = Subnet(rawValue: allowedIPString) else {
                    throw WireGuardParseError.peerHasInvalidAllowedIP(allowedIPString)
                }
                allowedIPs.append(allowedIP)
            }
            peer.allowedIPs = allowedIPs.map(\.rawValue)
        }
        if let endpointString = attributes["endpoint"] {
            // BEWARE, notation differs from init(rawValue:) in IPv6
            guard let endpoint = Endpoint(withWgRepresentation: endpointString) else {
                throw WireGuardParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpoint.rawValue
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw WireGuardParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.keepAlive = persistentKeepAlive
        }
        return try peer.tryBuild()
    }
}
