// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct MessageHandlerTests {
    @Test
    func givenTunnel_whenSendMessage_thenTranslatesDataToInputOutput() async throws {
        let log = DebugLog(lines: [
            .init(timestamp: Date(), level: .notice, message: "one"),
            .init(timestamp: Date(), level: .notice, message: "two"),
            .init(timestamp: Date(), level: .notice, message: "three")
        ])
        let output = Message.Output.debugLog(log: log)
        let strategy = FakeTunnelStrategy { _ in
            (try? JSONEncoder().encode(output)) ?? Data()
        }
        let sut = await Tunnel(.global, strategy: strategy) { _ in
            SharedTunnelEnvironment(profileId: nil)
        }

        let inputMessage = Message.Input.debugLog(sinceLast: 60.0, maxLevel: .debug)
        let input = try JSONEncoder().encode(inputMessage)
        let expOutputMessage = try #require(try await sut.sendMessage(
            input,
            to: UniqueID() // unused
        ))
        let expOutput = try JSONDecoder().decode(Message.Output.self, from: expOutputMessage)
        #expect(expOutput == output)
    }
}
