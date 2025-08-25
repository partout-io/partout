// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class AutoUpgradingSocket: LinkInterface {
    private let io: SocketIOInterface

    private let endpoint: ExtendedEndpoint

    private let upgradedBlock: @Sendable (ExtendedEndpoint) throws -> SocketIOInterface

    private let betterPathStream: PassthroughStream<Void>

    public init(
        endpoint: ExtendedEndpoint,
        upgradedBlock: @escaping @Sendable (ExtendedEndpoint) throws -> SocketIOInterface
    ) throws {
        io = try upgradedBlock(endpoint)
        self.endpoint = endpoint
        self.upgradedBlock = upgradedBlock
        // FIXME: ###, POSIXSocket, implement or receive betterPathStream
        betterPathStream = PassthroughStream()
    }

    public func connect() async throws {
        try await io.connect()
    }

    public nonisolated var remoteAddress: String {
        endpoint.address.rawValue
    }

    public nonisolated var remoteProtocol: EndpointProtocol {
        endpoint.proto
    }

    public func readPackets() async throws -> [Data] {
        try await io.readPackets()
    }

    public func writePackets(_ packets: [Data]) async throws {
        try await io.writePackets(packets)
    }

    public func setReadHandler(_ handler: @escaping ([Data]?, (any Error)?) -> Void) {
        Task.detached { [weak self] in
            while true {
                do {
                    let packets = try await self?.io.readPackets()
                    guard !Task.isCancelled else { return }
                    handler(packets, nil)
                } catch {
                    handler(nil, error)
                    return
                }
            }
        }
    }

    public var hasBetterPath: AsyncStream<Void> {
        betterPathStream.subscribe()
    }

    public func upgraded() throws -> LinkInterface {
        try AutoUpgradingSocket(endpoint: endpoint, upgradedBlock: upgradedBlock)
    }

    public func shutdown() {
        Task {
            await io.shutdown()
        }
    }

    public var linkDescription: String {
        "\(type(of: io))"
    }
}
