// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Wrapper for connecting over a TCP socket.
final class LegacyOpenVPNTCPLink: @unchecked Sendable {
    private let link: LinkInterface

    private let xorMethod: OpenVPN.ObfuscationMethod?

    private let xorMask: LegacyZD?

    // WARNING: not thread-safe, only use in setReadHandler()
    private var buffer: Data

    /// - Parameters:
    ///   - link: The underlying socket.
    ///   - xorMethod: The optional XOR method.
    init(link: LinkInterface, xorMethod: OpenVPN.ObfuscationMethod?) {
        precondition(link.linkType.plainType == .tcp)

        self.link = link
        self.xorMethod = xorMethod
        xorMask = xorMethod?.mask?.legacyZData
        buffer = Data(capacity: 1024 * 1024)
    }
}

// MARK: - LinkInterface

extension LegacyOpenVPNTCPLink: LinkInterface {
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
            buffer.reserveCapacity(buffer.count + packets.flatCount)
            for p in packets {
                buffer += p
            }
            var until = 0
            let processedPackets = PacketStream.packets(
                fromInboundStream: buffer,
                until: &until,
                xorMethod: self.xorMethod?.native ?? .none,
                xorMask: self.xorMask
            )
            buffer = buffer.subdata(in: until..<buffer.count)

            handler(processedPackets, error)
        }
    }

    func upgraded() async throws -> LinkInterface {
        LegacyOpenVPNTCPLink(link: try await link.upgraded(), xorMethod: xorMethod)
    }

    func shutdown() {
        link.shutdown()
    }
}

// MARK: - IOInterface

extension LegacyOpenVPNTCPLink {
    var fileDescriptor: UInt64? {
        nil
    }

    func readPackets() async throws -> [Data] {
        fatalError("readPackets() unavailable")
    }

    func writePackets(_ packets: [Data]) async throws {
        let stream = PacketStream.outboundStream(
            fromPackets: packets,
            xorMethod: xorMethod?.native ?? .none,
            xorMask: xorMask
        )
        guard !stream.isEmpty else { return }
        try await link.writePackets([stream])
    }
}

private extension OpenVPN.ObfuscationMethod {
    var native: XORMethodNative {
        switch self {
        case .xormask:
            return .mask

        case .xorptrpos:
            return .ptrPos

        case .reverse:
            return .reverse

        case .obfuscate:
            return .obfuscate

        @unknown default:
            return .mask
        }
    }
}
