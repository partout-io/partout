//
//  NEUDPSocket.swift
//  Partout
//
//  Created by Davide De Rosa on 8/27/17.
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
import NetworkExtension
import PartoutCore

/// Implementation of a `LinkObserver` via `NWUDPSession`.
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
            pp_log(ctx, .ne, .info, "Socket state is \(state.debugDescription)")
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
    public nonisolated func setReadHandler(_ handler: @escaping ([Data]?, Error?) -> Void) {

        // WARNING: runs in Network.framework queue
        nwSession.setReadHandler(handler, maxDatagrams: options.maxDatagrams)
    }

    public func writePackets(_ packets: [Data]) async throws {
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
