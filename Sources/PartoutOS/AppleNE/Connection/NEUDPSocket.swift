// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// An observer based on `NWUDPSession`.
@available(*, deprecated, message: "Use NESocketObserver")
public final class NEUDPObserver: LinkObserver {
    public struct Options: Sendable {
        public let maxDatagrams: Int
    }

    private let ctx: PartoutLoggerContext

    private nonisolated let nwSession: NWUDPSession

    private let options: Options

    private var observer: ValueObserver<NWUDPSession>?

    public init(_ ctx: PartoutLoggerContext, nwSession: NWUDPSession, options: Options) {
        self.ctx = ctx
        self.nwSession = nwSession
        self.options = options
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        observer = ValueObserver(nwSession)
        defer {
            observer = nil
        }
        try await observer?.waitForValue(on: \.state, timeout: timeout) { [weak self] state in
            guard let self else {
                return false
            }
            pp_log(ctx, .os, .info, "Socket state is \(state.debugDescription)")
            switch state {
            case .ready:
                return true
            case .cancelled, .failed:
                throw PartoutError(.linkNotActive)
            default:
                return false
            }
        }
        guard let remote = nwSession.resolvedEndpoint as? NWHostEndpoint,
              let port = UInt16(remote.port) else {
            throw PartoutError(.linkNotActive)
        }
        return NEUDPSocket(
            nwSession: nwSession,
            options: options,
            remoteAddress: remote.hostname,
            remoteProtocol: EndpointProtocol(.udp, port)
        )
    }
}

// MARK: - NEUDPSocket

private actor NEUDPSocket: LinkInterface {
    private nonisolated let nwSession: NWUDPSession

    private let options: NEUDPObserver.Options

    let remoteAddress: String

    let remoteProtocol: EndpointProtocol

    init(
        nwSession: NWUDPSession,
        options: NEUDPObserver.Options,
        remoteAddress: String,
        remoteProtocol: EndpointProtocol
    ) {
        self.nwSession = nwSession
        self.options = options
        self.remoteAddress = remoteAddress
        self.remoteProtocol = remoteProtocol
    }
}

// MARK: LinkInterface

extension NEUDPSocket {
    nonisolated var hasBetterPath: AsyncStream<Void> {
        stream(for: \.hasBetterPath, of: nwSession) { $0 }
            .map { _ in }
    }

    nonisolated func setReadHandler(_ handler: @escaping ([Data]?, Error?) -> Void) {

        // WARNING: runs in Network.framework queue
        nwSession.setReadHandler(handler, maxDatagrams: options.maxDatagrams)
    }

    nonisolated func upgraded() -> LinkInterface {
        Self(
            nwSession: NWUDPSession(upgradeFor: nwSession),
            options: options,
            remoteAddress: remoteAddress,
            remoteProtocol: remoteProtocol
        )
    }

    nonisolated func shutdown() {
        nwSession.cancel()
    }
}

// MARK: IOInterface

extension NEUDPSocket {
    nonisolated var fileDescriptor: UInt64? {
        nil
    }

    func readPackets() async throws -> [Data] {
        fatalError("readPackets() unavailable")
    }

    func writePackets(_ packets: [Data]) async throws {
        guard !packets.isEmpty else {
            return
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nwSession.writeMultipleDatagrams(packets) { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            nwSession.cancel()
        }
    }
}
