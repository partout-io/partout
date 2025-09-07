// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutWireGuard
@testable import PartoutWireGuardCross
import Foundation
import PartoutCore
import Testing

struct MappersTests {
    @Test
    func givenEndpointString_whenMapped_thenReverts() throws {
        let sut = [
            "1.2.3.4:10000",
            "[1:2:3::4]:10000"
        ]
        let expected: [(String, UInt16)] = [
            ("1.2.3.4", 10000),
            ("1:2:3::4", 10000)
        ]
        for (i, raw) in sut.enumerated() {
            let wg = try #require(Endpoint(from: raw))
            // work around dumb macro compile error
//            let kit = try #require(PartoutCore.Endpoint(wg: wg))
            let kit = try {
                let kit = PartoutCore.Endpoint(wg: wg)
                return try #require(kit)
            }()
            let kitEndpoint = try kit.toWireGuardEndpoint()
            #expect(wg == kitEndpoint, "Index \(i) failed")

            let pair = expected[i]
            #expect(wg.host.debugDescription == pair.0)
            #expect(wg.port.rawValue == pair.1)
            #expect(kit.address.rawValue == pair.0)
            #expect(kit.port == pair.1)
        }
    }

    @Test
    func givenConfigurationWithAllowedIPs_whenMapped_thenReverts() throws {
        let quickConfig = """
[Interface]
PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
Address = 10.8.0.6/24
DNS = 1.1.1.1

[Peer]
PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
PresharedKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
AllowedIPs = 8.8.4.0/24, 8.8.8.0/24, 8.34.208.0/20, 8.35.192.0/20, 23.236.48.0/20, 23.251.128.0/19, 212.188.34.209/32, 172.217.169.138/32, 142.250.187.106/32, 142.250.186.33/32, 172.217.17.23/32
PersistentKeepalive = 0
Endpoint = 1.2.3.4:12345
"""
        let wg = try TunnelConfiguration(fromWgQuickConfig: quickConfig)
        let sut = try WireGuard.Configuration(wg: wg)

        #expect(try sut.interface.toWireGuardConfiguration() == wg.interface)
        try sut.peers.enumerated().forEach { i, peer in
            try #expect(peer.toWireGuardConfiguration() == wg.peers[i])
        }

        let sutCfg = try sut.toWireGuardConfiguration()
        #expect(wg == sutCfg)
    }

    @Test
    func givenConfigurationWithManyAllowedIPs_whenMapped_thenReverts() throws {
        let quickConfig = """
[Interface]
PrivateKey = OE4Bp66J0y2xT475hVZrO96X7kfZZad6LUwWAn4oBmM=
Address = 10.8.0.3/24
DNS = 1.1.1.1

[Peer]
PublicKey = rug4kdIOf8FMDthbjLaDEdZs+5rPi6HnAaabzrmigWc=
PresharedKey = muX7YCVPFBcw7l/9Dpde2ExYeGOyBLo9j3ZBlapTKxQ=
AllowedIPs = 8.8.4.0/24, 8.8.8.0/24, 8.34.208.0/20, 8.35.192.0/20, 23.236.48.0/20, 23.251.128.0/19, 34.0.0.0/10, 35.184.0.0/13, 35.192.0.0/14, 35.196.0.0/15, 35.198.0.0/16, 35.199.0.0/17, 35.199.128.0/18, 35.200.0.0/13, 35.208.0.0/12, 64.18.0.0/20, 64.233.160.0/19, 66.102.0.0/20, 66.249.64.0/19, 70.32.128.0/19, 72.14.192.0/18, 74.114.24.0/21, 74.125.0.0/16, 104.132.0.0/23, 104.133.0.0/23, 104.134.0.0/15, 104.156.64.0/18, 104.237.160.0/19, 108.59.80.0/20, 108.170.192.0/18, 108.177.0.0/15, 130.211.0.0/16, 136.112.0.0/12, 142.250.0.0/15, 146.148.0.0/17, 162.216.148.0/22, 162.222.176.0/21, 172.110.32.0/21, 172.217.0.0/16, 172.253.0.0/16, 173.194.0.0/16, 173.255.112.0/20, 192.158.28.0/22, 192.178.0.0/15, 193.186.4.0/24, 199.36.154.0/23, 199.36.156.0/24, 199.192.112.0/22, 199.223.232.0/21, 207.223.160.0/20, 208.65.152.0/22, 208.68.108.0/22, 208.81.188.0/22, 208.117.224.0/19, 209.85.128.0/17, 216.58.192.0/19, 216.239.32.0/19, 216.239.36.0/24, 216.239.38.0/23, 216.239.40.0/22, 34.64.0.0/10, 34.128.0.0/10, 142.251.141.46/32, 212.188.34.209/32, 172.217.169.138/32, 142.250.187.106/32, 142.250.186.33/32, 172.217.17.238/32, 172.217.20.78/32, 142.250.185.238/32, 74.125.156.170/32, 185.38.0.76/32, 212.188.34.207/32, 108.177.14.138/32, 142.251.40.139/32, 142.251.40.102/32, 108.177.14.113/32, 142.251.40.138/32, 142.250.74.78/32, 142.251.141.145/32, 142.250.74.110/32, 142.251.40.103/32, 142.250.74.46/32, 108.177.97.78/32, 142.250.74.14/32, 142.250.74.78/32
PersistentKeepalive = 0
Endpoint = 176.124.208.254:51820
"""

        let wg = try TunnelConfiguration(fromWgQuickConfig: quickConfig)
        let sut = try WireGuard.Configuration(wg: wg)
        let sutCfg = try sut.toWireGuardConfiguration()
        #expect(wg == sutCfg)
    }
}
