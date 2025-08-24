// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOpenVPN
#endif

/// Wrapper for connecting over a UDP socket.
final class OpenVPNUDPLink: @unchecked Sendable {
    private let link: LinkInterface

    private let xor: XORProcessor?

    /// - Parameters:
    ///   - link: The underlying socket.
    ///   - xorMethod: The optional XOR method.
    convenience init(link: LinkInterface, xorMethod: OpenVPN.ObfuscationMethod?) {
        precondition(link.linkType.plainType == .udp)
        self.init(link: link, xor: xorMethod.map(XORProcessor.init(method:)))
    }

    init(link: LinkInterface, xor: XORProcessor?) {
        self.link = link
        self.xor = xor
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

    func setReadHandler(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
        link.setReadHandler { [weak self] packets, error in
            guard let self, let packets, !packets.isEmpty else {
                return
            }
            if let xor {
                let processedPackets = xor.processPackets(packets, outbound: false)
                handler(processedPackets, error)
                return
            }
            handler(packets, error)
        }
    }

    func upgraded() throws -> LinkInterface {
        OpenVPNUDPLink(link: try link.upgraded(), xor: xor)
    }

    func shutdown() {
        link.shutdown()
    }
}

// MARK: - IOInterface

extension OpenVPNUDPLink {
    func readPackets() async throws -> [Data] {
        fatalError("readPackets() unavailable")
    }

    func writePackets(_ packets: [Data]) async throws {
        guard !packets.isEmpty else {
            assertionFailure("Writing empty packets?")
            return
        }
        if let xor {
            let processedPackets = xor.processPackets(packets, outbound: true)
            try await link.writePackets(processedPackets)
            return
        }
        try await link.writePackets(packets)
    }
}
