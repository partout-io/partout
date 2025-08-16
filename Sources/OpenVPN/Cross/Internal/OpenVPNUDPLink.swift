// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutOpenVPN

/// Wrapper for connecting over a UDP socket.
final class OpenVPNUDPLink {
    private let link: LinkInterface

    private let proc: PacketProcessor?

    /// - Parameters:
    ///   - link: The underlying socket.
    ///   - method: The optional obfuscation method.
    convenience init(link: LinkInterface, method: OpenVPN.ObfuscationMethod?) {
        precondition(link.linkType.plainType == .udp)
        self.init(link: link, proc: method.map(PacketProcessor.init(method:)))
    }

    init(link: LinkInterface, proc: PacketProcessor?) {
        self.link = link
        self.proc = proc
    }
}

// MARK: - LinkInterface

extension OpenVPNUDPLink: LinkInterface {
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

    func upgraded() -> LinkInterface {
        OpenVPNUDPLink(link: link.upgraded(), proc: proc)
    }

    func shutdown() {
        link.shutdown()
    }
}

// MARK: - IOInterface

extension OpenVPNUDPLink {
    func setReadHandler(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
        link.setReadHandler { [weak self] packets, error in
            guard let self, let packets, !packets.isEmpty else {
                return
            }
            if let proc {
                let processedPackets = proc.processPackets(packets, direction: .inbound)
                handler(processedPackets, error)
                return
            }
            handler(packets, error)
        }
    }

    func writePackets(_ packets: [Data]) async throws {
        guard !packets.isEmpty else {
            assertionFailure("Writing empty packets?")
            return
        }
        if let proc {
            let processedPackets = proc.processPackets(packets, direction: .outbound)
            try await link.writePackets(processedPackets)
            return
        }
        try await link.writePackets(packets)
    }
}
