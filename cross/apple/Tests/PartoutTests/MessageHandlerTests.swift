// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct MessageHandlerTests {
    @Test
    func givenTunnel_whenSendMessage_thenTranslatesDataToInputOutput() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let log = DebugLog(lines: [
            .init(timestamp: timestamp, level: .notice, message: "one"),
            .init(timestamp: timestamp, level: .notice, message: "two"),
            .init(timestamp: timestamp, level: .notice, message: "three")
        ])
        let output = Message.Output.debugLog(log: log)
        let strategy = FakeTunnelStrategy { _ in
            (try? JSONEncoder.shared().encode(output)) ?? Data()
        }
        let sut = Tunnel(.global, strategy: strategy) { _ in
            SharedTunnelEnvironment(profileId: nil)
        }

        let inputMessage = Message.Input.debugLog(sinceLast: 60.0, maxLevel: .debug)
        let input = try JSONEncoder.shared().encode(inputMessage)
        let expOutputMessage = try #require(try await sut.sendMessage(
            input,
            to: UniqueID() // unused
        ))
        let expOutput = try JSONDecoder.shared().decode(Message.Output.self, from: expOutputMessage)
        #expect(expOutput == output)
    }
}
