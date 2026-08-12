// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import PartoutWireGuard
import Testing

struct ModuleTests {
    @Test
    func givenBuilder_whenEmptyPeers_thenFails() throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var sut = WireGuardModule.Builder()
        sut.configurationBuilder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        #expect(throws: PartoutError.self, performing: { try sut.build() })

        sut.configurationBuilder?.peers = [.init(publicKey: pubkey)]
        let module = try sut.build()

        #expect(module.configuration?.interface.privateKey.rawValue == pvtkey)
        #expect(module.configuration?.peers.first?.publicKey.rawValue == pubkey)
    }

    @Test
    func givenModule_whenSerialize_thenProducesWgQuickConfig() throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var sut = WireGuardModule.Builder()
        sut.configurationBuilder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        sut.configurationBuilder?.peers = [
            {
                var peer = WireGuard.RemoteInterface.Builder(publicKey: pubkey)
                peer.allowedIPs = ["10.0.0.0/24"]
                return peer
            }()
        ]

        let module = try sut.build()
        let serialized = try module.serialized()
        let parsed = try StandardWireGuardParser().configuration(from: serialized)

        #expect(parsed.interface.privateKey.rawValue == pvtkey)
        #expect(parsed.peers.count == 1)
        #expect(parsed.peers.first?.publicKey.rawValue == pubkey)
        #expect(parsed.peers.first?.allowedIPs.map(\.rawValue) == ["10.0.0.0/24"])
    }
}
