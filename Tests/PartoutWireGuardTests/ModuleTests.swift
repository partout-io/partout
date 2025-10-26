// SPDX-FileCopyrightText: 2025 Davide De Rosa
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
}
