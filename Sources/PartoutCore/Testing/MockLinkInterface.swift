// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public final class MockLinkObserver: LinkObserver {
    public let remoteAddress: String

    public let remoteProtocol: EndpointProtocol

    public var linkBlock: (MockLinkInterface) -> Void

    public var activityError: Error?

    public init(
        to endpoint: ExtendedEndpoint,
        linkBlock: @escaping (MockLinkInterface) -> Void = { _ in }
    ) {
        remoteAddress = endpoint.address.rawValue
        remoteProtocol = endpoint.proto
        self.linkBlock = linkBlock
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        if let activityError {
            throw activityError
        }
        let newLink = MockLinkInterface(remoteAddress: remoteAddress, remoteProtocol: remoteProtocol)
        linkBlock(newLink)
        return newLink
    }

    public func shutdown() {
    }
}

public final class MockLinkInterface: LinkInterface {
    public let remoteAddress: String

    public let remoteProtocol: EndpointProtocol

    nonisolated(unsafe)
    public var hasBetterPath: AsyncStream<Void>

    public init(remoteAddress: String, remoteProtocol: EndpointProtocol) {
        self.remoteAddress = remoteAddress
        self.remoteProtocol = remoteProtocol
        hasBetterPath = AsyncStream {
            nil
        }
    }

    public var fileDescriptor: UInt64? {
        nil
    }

    public func upgraded() -> LinkInterface {
        self
    }

    public func shutdown() {
    }

    public func setReadHandler(_ handler: @escaping ([Data]?, Error?) -> Void) {
    }

    public func readPackets() async throws -> [Data] {
        []
    }

    public func writePackets(_ packets: [Data]) async throws {
    }
}
