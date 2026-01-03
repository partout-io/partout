// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``LinkInterface`` able to upgrade to a new instance.
public final class AutoUpgradingLink: LinkInterface {
    public typealias IOBlock = @Sendable (ExtendedEndpoint) async throws -> SocketIOInterface

    private let endpoint: ExtendedEndpoint

    private let ioBlock: IOBlock

    private let betterPathBlock: BetterPathBlock

    private let io: SocketIOInterface

    private let betterPathStream: PassthroughStream<UniqueID, Void>

    public init(
        endpoint: ExtendedEndpoint,
        ioBlock: @escaping IOBlock,
        betterPathBlock: @escaping BetterPathBlock
    ) async throws {
        self.endpoint = endpoint
        self.ioBlock = ioBlock
        self.betterPathBlock = betterPathBlock
        io = try await ioBlock(endpoint)
        betterPathStream = try betterPathBlock()
    }

    public nonisolated var remoteAddress: String {
        endpoint.address.rawValue
    }

    public nonisolated var remoteProtocol: EndpointProtocol {
        endpoint.proto
    }

    public var fileDescriptor: UInt64? {
        io.fileDescriptor
    }

    public func readPackets() async throws -> [Data] {
        try await io.readPackets()
    }

    public func writePackets(_ packets: [Data]) async throws {
        try await io.writePackets(packets)
    }

    public func setReadHandler(_ handler: @escaping @Sendable ([Data]?, (any Error)?) -> Void) {
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

    public func upgraded() async throws -> LinkInterface {
        try await AutoUpgradingLink(
            endpoint: endpoint,
            ioBlock: ioBlock,
            betterPathBlock: betterPathBlock
        )
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
