//
//  OpenVPNTCPLink.swift
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

/// Wrapper for connecting over a TCP socket.
final class OpenVPNTCPLink {
    private let link: LinkInterface

    private let proc: PacketProcessor

    // WARNING: not thread-safe, only use in setReadHandler()
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

    func upgraded() -> LinkInterface {
        OpenVPNTCPLink(link: link.upgraded(), proc: proc)
    }

    func shutdown() {
        link.shutdown()
    }
}

// MARK: - IOInterface

extension OpenVPNTCPLink {
    func setReadHandler(_ handler: @escaping ([Data]?, Error?) -> Void) {
        link.setReadHandler { [weak self] packets, error in
            guard let self else {
                return
            }
            guard error == nil, let packets else {
                handler(nil, error)
                return
            }

            buffer += packets.joined()
            var until = 0
            let processedPackets = proc.packets(fromStream: buffer, until: &until)
            buffer = buffer.subdata(in: until..<buffer.count)

            handler(processedPackets, error)
        }
    }

    func writePackets(_ packets: [Data]) async throws {
        let stream = proc.stream(fromPackets: packets)
        try await link.writePackets([stream])
    }
}
