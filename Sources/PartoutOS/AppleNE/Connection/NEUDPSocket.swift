// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// An observer based on `NWUDPSession`.
public final class NEUDPObserver: LinkObserver {
    public struct Options: Sendable {
        public let maxDatagrams: Int
        public let withSafeValueObserver: Bool
    }

    protocol StateObserver {
        func waitForState(
            timeout: Int,
            onState: @escaping (NWUDPSessionState) throws -> Bool
        ) async throws
    }

    private let ctx: PartoutLoggerContext

    private nonisolated let nwSession: NWUDPSession

    private let options: Options

    private var observer: StateObserver?

    public init(_ ctx: PartoutLoggerContext, nwSession: NWUDPSession, options: Options) {
        self.ctx = ctx
        self.nwSession = nwSession
        self.options = options
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        if options.withSafeValueObserver {
            observer = SafeObserver(nwSession)
        } else {
            observer = LegacyObserver(nwSession)
        }
        defer {
            observer = nil
        }
        try await observer?.waitForState(timeout: timeout) { [weak self] state in
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

    private let readStream: AsyncThrowingStream<[Data], Error>

    private let readContinuation: AsyncThrowingStream<[Data], Error>.Continuation

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

        var newReadContinuation: AsyncThrowingStream<[Data], Error>.Continuation?
        readStream = AsyncThrowingStream { continuation in
            newReadContinuation = continuation
        }
        guard let newReadContinuation else {
            fatalError("withReadPackets requires non-nil readContinuation")
        }
        readContinuation = newReadContinuation

        // WARNING: runs in Network.framework queue
        nwSession.setReadHandler({ [newReadContinuation] packets, error in
            if let error {
                newReadContinuation.finish(throwing: error)
                return
            }
            guard let packets, !packets.isEmpty else { return }
            newReadContinuation.yield(packets)
        }, maxDatagrams: options.maxDatagrams)
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

    nonisolated func close() {
        nwSession.cancel()
    }
}

// MARK: IOInterface

extension NEUDPSocket {
    func readPackets() async throws -> [Data] {
        try await readStream.nextElement() ?? []
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

// MARK: - State observers

private struct SafeObserver: NEUDPObserver.StateObserver {
    let backend: SafeValueObserver<NWUDPSession>

    init(_ session: NWUDPSession) {
        backend = SafeValueObserver(session)
    }

    func waitForState(timeout: Int, onState: @escaping (NWUDPSessionState) throws -> Bool) async throws {
        try await backend.waitForValue(on: \.state, timeout: timeout) { state in
            try onState(state)
        }
    }
}

private struct LegacyObserver: NEUDPObserver.StateObserver {
    let backend: ValueObserver<NWUDPSession>

    init(_ session: NWUDPSession) {
        backend = ValueObserver(session)
    }

    func waitForState(timeout: Int, onState: @escaping (NWUDPSessionState) throws -> Bool) async throws {
        try await backend.waitForValue(on: \.state, timeout: timeout) { state in
            try onState(state)
        }
    }
}
