//
//  OpenVPNUDPLink.swift
//  Partout
//
//  Created by Davide De Rosa on 5/23/19.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
    func setReadHandler(_ handler: @escaping ([Data]?, Error?) -> Void) {
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
