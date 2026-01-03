// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class MockTunnelInterface: IOInterface {
    public init() {
    }

    public var fileDescriptor: UInt64? {
        nil
    }

    public func readPackets() async throws -> [Data] {
        []
    }

    public func writePackets(_ packets: [Data]) async throws {
    }
}
