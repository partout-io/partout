// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class MockTunnelController: TunnelController, @unchecked Sendable {
    public var onSetTunnelSettings: (TunnelRemoteInfo?) async throws -> Void = { _ in }

    public var onCancelTunnelConnection: (Error?) -> Void = { _ in }

    public init() {
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface {
        try await onSetTunnelSettings(info)
        return MockTunnelInterface()
    }

    public func configureSockets(with descriptors: [UInt64]) {
    }

    public func clearTunnelSettings(_ tunnel: IOInterface) async {
    }

    public func setReasserting(_ reasserting: Bool) {
    }

    public func cancelTunnelConnection(with error: Error?) {
        onCancelTunnelConnection(error)
    }
}
