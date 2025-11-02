// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelStrategy {
    public func sendMessage(_ input: Message.Input, to profileId: Profile.ID) async throws -> Message.Output? {
        let encoded = try JSONEncoder().encode(input)
        guard let output = try await sendMessage(encoded, to: profileId) else {
            return nil
        }
        return try JSONDecoder().decode(Message.Output.self, from: output)
    }
}
