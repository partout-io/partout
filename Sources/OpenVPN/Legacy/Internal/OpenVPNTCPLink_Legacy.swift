// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCryptoOpenSSL_ObjC
internal import _PartoutOpenVPNLegacy_ObjC
import Foundation
import PartoutCore
import PartoutOpenVPN

/// Wrapper for connecting over a TCP socket.
final class OpenVPNTCPLink: @unchecked Sendable {
    private let link: LinkInterface

    private let xorMethod: OpenVPN.ObfuscationMethod?

    private let xorMask: ZeroingData?

    // WARNING: not thread-safe, only use in setReadHandler()
    private var buffer: Data

    /// - Parameters:
    ///   - link: The underlying socket.
    ///   - xorMethod: The optional XOR method.
    init(link: LinkInterface, xorMethod: OpenVPN.ObfuscationMethod?) {
        precondition(link.linkType.plainType == .tcp)

        self.link = link
        self.xorMethod = xorMethod
        xorMask = xorMethod?.mask?.zData
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
        OpenVPNTCPLink(link: link.upgraded(), xorMethod: xorMethod)
    }

    func shutdown() {
        link.shutdown()
    }
}

// MARK: - IOInterface

extension OpenVPNTCPLink {
    func setReadHandler(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
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

    func writePackets(_ packets: [Data]) async throws {
        let stream = PacketStream.outboundStream(
            fromPackets: packets,
            xorMethod: xorMethod?.native ?? .none,
            xorMask: xorMask
        )
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
