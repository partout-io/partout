// SPDX-License-Identifier: MIT
// Copyright © 2018-2021 WireGuard LLC. All Rights Reserved.

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
            if let commentRange = line.ranges(of: "#").first {
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
                    let interfaceSectionKeys: Set<String> = ["privatekey", "listenport", "address", "dns", "dnsoverhttpsurl", "dnsovertlsservername", "mtu", "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"]
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
        if let awg = interface.amneziaParameters {
            if let jc = awg.jc { output.append("Jc = \(jc)\n") }
            if let jmin = awg.jmin { output.append("Jmin = \(jmin)\n") }
            if let jmax = awg.jmax { output.append("Jmax = \(jmax)\n") }
            if let s1 = awg.s1 { output.append("S1 = \(s1)\n") }
            if let s2 = awg.s2 { output.append("S2 = \(s2)\n") }
            if let s3 = awg.s3 { output.append("S3 = \(s3)\n") }
            if let s4 = awg.s4 { output.append("S4 = \(s4)\n") }
            if let h1 = awg.h1 { output.append("H1 = \(h1)\n") }
            if let h2 = awg.h2 { output.append("H2 = \(h2)\n") }
            if let h3 = awg.h3 { output.append("H3 = \(h3)\n") }
            if let h4 = awg.h4 { output.append("H4 = \(h4)\n") }
            if let i1 = awg.i1 { output.append("I1 = \(i1)\n") }
            if let i2 = awg.i2 { output.append("I2 = \(i2)\n") }
            if let i3 = awg.i3 { output.append("I3 = \(i3)\n") }
            if let i4 = awg.i4 { output.append("I4 = \(i4)\n") }
            if let i5 = awg.i5 { output.append("I5 = \(i5)\n") }
        }

        for peer in peers {
            output.append("\n[Peer]\n")
            output.append("PublicKey = \(peer.publicKey.rawValue)\n")
            if let preSharedKey = peer.preSharedKey?.rawValue, !preSharedKey.isEmpty {
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
            for entry in dnsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
                guard let addr = Address(rawValue: entry) else { continue }
                if addr.isIPAddress {
                    dnsServers.append(addr)
                } else {
                    dnsSearch.append(addr.rawValue)
                }
            }
            var dns = DNSModule.Builder()
            dns.servers = dnsServers.map(\.rawValue)
            dns.domains = dnsSearch
            interface.dns = dns
        }
        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw WireGuardParseError.interfaceHasInvalidMTU(mtuString)
            }
            interface.mtu = mtu
        }

        let awgKeys = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"]
        if awgKeys.contains(where: { attributes[$0] != nil }) {
            var awg = WireGuard.AmneziaParameters.Builder()
            awg.jc = attributes["jc"].flatMap { UInt16($0) }
            awg.jmin = attributes["jmin"].flatMap { UInt16($0) }
            awg.jmax = attributes["jmax"].flatMap { UInt16($0) }
            awg.s1 = attributes["s1"].flatMap { UInt16($0) }
            awg.s2 = attributes["s2"].flatMap { UInt16($0) }
            awg.s3 = attributes["s3"].flatMap { UInt16($0) }
            awg.s4 = attributes["s4"].flatMap { UInt16($0) }
            awg.h1 = attributes["h1"]
            awg.h2 = attributes["h2"]
            awg.h3 = attributes["h3"]
            awg.h4 = attributes["h4"]
            awg.i1 = attributes["i1"]
            awg.i2 = attributes["i2"]
            awg.i3 = attributes["i3"]
            awg.i4 = attributes["i4"]
            awg.i5 = attributes["i5"]
            interface.amneziaParameters = awg
        }

        return try interface.build()
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
        return try peer.build()
    }
}
