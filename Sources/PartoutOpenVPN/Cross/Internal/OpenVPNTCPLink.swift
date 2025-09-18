// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Wrapper for connecting over a TCP socket.
final class OpenVPNTCPLink {
    private let link: LinkInterface

    private let proc: PacketProcessor

    // WARNING: not thread-safe, only use in setReadHandler()
    nonisolated(unsafe)
    private var buffer: Data

    /// - Parameters:
    ///   - link: The underlying socket.
    ///   - method: The optional obfuscation method.
    convenience init(link: LinkInterface, method: OpenVPN.ObfuscationMethod?) {
        precondition(link.linkType.plainType == .tcp)
        self.init(link: link, proc: PacketProcessor(method: method))
    }

    init(link: LinkInterface, proc: PacketProcessor) {
        self.link = link
        self.proc = proc
        buffer = Data(capacity: 1024 * 1024)
    }
}

// MARK: - LinkInterface

extension OpenVPNTCPLink: LinkInterface {
    var linkType: IPSocketType {
        link.linkType
    }

    var remoteAddress: String {
        link.remoteAddress
    }

    var remoteProtocol: EndpointProtocol {
        link.remoteProtocol
    }

    var hasBetterPath: AsyncStream<Void> {
        link.hasBetterPath
    }

    func setReadHandler(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
        link.setReadHandler { [weak self] packets, error in
            guard let self else {
                return
            }
            guard error == nil, let packets else {
                handler(nil, error)
                return
            }

            // FIXME: #190, This is very inefficient (TCP)
            buffer += packets.joined()
            var until = 0
            let processedPackets = proc.packets(fromStream: buffer, until: &until)
            buffer = buffer.subdata(in: until..<buffer.count)

            handler(processedPackets, error)
        }
    }

    func upgraded() async throws -> LinkInterface {
        OpenVPNTCPLink(link: try await link.upgraded(), proc: proc)
    }

    func shutdown() {
        link.shutdown()
    }
}

// MARK: - IOInterface

extension OpenVPNTCPLink {
    var fileDescriptor: UInt64? {
        link.fileDescriptor
    }

    func readPackets() async throws -> [Data] {
        fatalError("readPackets() unavailable")
    }

    func writePackets(_ packets: [Data]) async throws {
        let stream = proc.stream(fromPackets: packets)
        guard !stream.isEmpty else { return }
        try await link.writePackets([stream])
    }
}
