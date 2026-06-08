// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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

    func upgraded() async throws -> LinkInterface {
        OpenVPNTCPLink(link: try await link.upgraded(), proc: proc)
    }

    func close() {
        link.close()
    }
}

// MARK: - IOInterface

extension OpenVPNTCPLink {
    var fileDescriptor: FileDescriptor? {
        link.fileDescriptor
    }

    func readPackets() async throws -> [Data] {
        let packets = try await link.readPackets()

        // FIXME: #214, TCP is very slow
        buffer.reserveCapacity(buffer.count + packets.flatCount)
        for p in packets {
            buffer.append(p)
        }
        var until = 0
        let processedPackets = proc.packets(fromStream: buffer, until: &until)
        buffer = buffer.subdata(in: until..<buffer.count)

        return processedPackets
    }

    func writePackets(_ packets: [Data]) async throws {
        let stream = proc.stream(fromPackets: packets)
        guard !stream.isEmpty else { return }
        try await link.writePackets([stream])
    }
}
