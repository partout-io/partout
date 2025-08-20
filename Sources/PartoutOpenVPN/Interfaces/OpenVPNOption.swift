// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension OpenVPN {

    /// The supported options of an OpenVPN configuration file.
    public enum Option: String, CaseIterable, Sendable {

        // MARK: Continuation

        case continuation = "^push-continuation [12]"

        // MARK: Unsupported

        // check blocks first
        case connectionBlock = "^<connection>"

        case connectionProxy = "^\\w+-proxy"

        case externalFiles = "^(auth-user-pass|ca|cert|key|tls-auth|tls-crypt) "

        case fragment = "^fragment"

        case tlsCryptV2 = "tls-crypt-v2"

        // MARK: General

        case cipher = "^cipher +[^,\\s]+"

        case dataCiphers = "^(data-ciphers|ncp-ciphers) +[^,\\s]+(:[^,\\s]+)*"

        case dataCiphersFallback = "^data-ciphers-fallback +[^,\\s]+"

        case auth = "^auth +[\\w\\-]+"

        case compLZO = "^comp-lzo.*"

        case compress = "^compress.*"

        case keyDirection = "^key-direction +\\d"

        case ping = "^ping +\\d+"

        case pingRestart = "^ping-restart +\\d+"

        case keepAlive = "^keepalive +\\d+ ++\\d+"

        case renegSec = "^reneg-sec +\\d+"

        case blockBegin = "^<[\\w\\-]+>"

        case blockEnd = "^<\\/[\\w\\-]+>"

        // MARK: Client

        case proto = "^proto +(udp[46]?|tcp[46]?)"

        case port = "^port +\\d+"

        case remote = "^remote +[^ ]+( +\\d+)?( +(udp[46]?|tcp[46]?))?"

        case authUserPass = "^auth-user-pass"

        case staticChallenge = "^static-challenge"

        case eku = "^remote-cert-tls +server"

        case remoteRandom = "^remote-random"

        case remoteRandomHostname = "^remote-random-hostname"

        case mtu = "^tun-mtu +\\d+"

        // MARK: Server

        case authToken = "^auth-token +[a-zA-Z0-9/=+]+"

        case peerId = "^peer-id +[0-9]+"

        // MARK: Routing

        case topology = "^topology +(net30|p2p|subnet)"

        case ifconfig = "^ifconfig +[\\d\\.]+ [\\d\\.]+"

        case ifconfig6 = "^ifconfig-ipv6 +[\\da-fA-F:]+/\\d+ [\\da-fA-F:]+"

        case route = "^route +[\\d\\.]+( +[\\d\\.]+){0,2}"

        case route6 = "^route-ipv6 +[\\da-fA-F:]+/\\d+( +[\\da-fA-F:]+){0,2}"

        case gateway = "^route-gateway +[\\d\\.]+"

        case dns = "^dhcp-option +DNS6? +[\\d\\.a-fA-F:]+"

        case domain = "^dhcp-option +DOMAIN +[^ ]+"

        case domainSearch = "^dhcp-option +DOMAIN-SEARCH +[^ ]+"

        case proxy = "^dhcp-option +PROXY_(HTTPS? +[^ ]+ +\\d+|AUTO_CONFIG_URL +[^ ]+)"

        case proxyBypass = "^dhcp-option +PROXY_BYPASS +.+"

        case redirectGateway = "^redirect-gateway.*"

        case routeNoPull = "^route-nopull"

        // MARK: Extra

        case xorInfo = "^scramble +(xormask|xorptrpos|reverse|obfuscate)[\\s]?([^\\s]+)?"
    }
}

extension OpenVPN.Option {
    public func regularExpression() throws -> NSRegularExpression {
        try NSRegularExpression(pattern: rawValue)
    }
}

extension OpenVPN.Option {
    var isServerOnly: Bool {
        switch self {
        case .authToken, .peerId:
            return true
        default:
            return false
        }
    }
}
