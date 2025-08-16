// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
import PartoutCore

/// Implementation of a ``/PartoutCore/LinkObserver`` via `NWTCPConnection`.
public final class NESocketObserver: LinkObserver, @unchecked Sendable {
    public struct Options: Sendable {
        public let proto: IPSocketType

        public let minLength: Int

        public let maxLength: Int
    }

    private let queue: DispatchQueue

    private let ctx: PartoutLoggerContext

    private let nwConnection: NWConnection

    private let options: Options

    private var readyContinuation: CheckedContinuation<Void, Error>?

    public init(_ ctx: PartoutLoggerContext, nwConnection: NWConnection, options: Options) {
        queue = DispatchQueue(label: "NESocket", attributes: .concurrent)
        self.ctx = ctx
        self.nwConnection = nwConnection
        self.options = options

        nwConnection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { [weak self] in
                self?.onStateUpdate(state)
            }
        }
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        let isReady = try await withThrowingTaskGroup(returning: Bool.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { [weak self] continuation in
                    guard let self else { return }
                    self.readyContinuation = continuation
                    self.nwConnection.start(queue: self.queue)
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(milliseconds: timeout)
                guard !Task.isCancelled else {
                    throw PartoutError(.timeout)
                }
                self?.nwConnection.cancel()
            }

            // return first task to finish and cancel the other one
            try await group.next()
            group.cancelAll()
            return nwConnection.state == .ready
        }
        guard isReady else {
            throw PartoutError(.connectionNotStarted)
        }

        let rawAddress: String
        let rawPort: UInt16
        switch nwConnection.endpoint {
        case .hostPort(let host, let port):
            switch host {
            case .ipv4(let addr):
                // XXX: this might be unsafe
                rawAddress = addr.debugDescription
            case .ipv6(let addr):
                // XXX: this might be unsafe
                rawAddress = addr.debugDescription
            case .name(let name, _):
                rawAddress = name
            default:
                throw PartoutError(.connectionNotStarted)
            }
            rawPort = port.rawValue
        default:
            throw PartoutError(.connectionNotStarted)
        }

        let socket = NESocket(
            queue: queue,
            nwConnection: nwConnection,
            options: options,
            remoteAddress: rawAddress,
            remoteProtocol: EndpointProtocol(
                options.proto,
                rawPort
            )
        )
        await socket.configure()
        return socket
    }
}

private extension NESocketObserver {
    func onStateUpdate(_ state: NWConnection.State) {
        pp_log(ctx, .ne, .info, "Socket state is \(state.debugDescription)")
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
        case .failed(let error):
            readyContinuation?.resume(throwing: error)
        case .waiting(let error):
            readyContinuation?.resume(throwing: error)
        case .cancelled:
            readyContinuation?.resume(throwing: PartoutError(.operationCancelled))
        case .preparing, .setup:
            break
        @unknown default:
            readyContinuation?.resume(throwing: PartoutError(.unhandled))
        }
    }
}

// MARK: - NESocket

private actor NESocket: LinkInterface {
    private let queue: DispatchQueue

    private let nwConnection: NWConnection

    private let options: NESocketObserver.Options

    let remoteAddress: String

    let remoteProtocol: EndpointProtocol

    private let betterPathStream: PassthroughStream<Void>

    private var writeBlock: (@Sendable ([Data]) async throws -> Void)?

    init(
        queue: DispatchQueue,
        nwConnection: NWConnection,
        options: NESocketObserver.Options,
        remoteAddress: String,
        remoteProtocol: EndpointProtocol
    ) {
        self.queue = queue
        self.nwConnection = nwConnection
        self.options = options
        self.remoteAddress = remoteAddress
        self.remoteProtocol = remoteProtocol
        betterPathStream = PassthroughStream()
    }

    func configure() {
        switch remoteProtocol.socketType.plainType {
        case .udp:
            writeBlock = { [weak self] packets in
                guard let self else { return }
                try await withThrowingTaskGroup { [weak self] group in
                    packets.forEach { [weak self] packet in
                        group.addTask { [weak self] in
                            try await self?.asyncWritePacket(packet)
                        }
                    }
                    try await group.waitForAll()
                }
            }
        case .tcp:
            writeBlock = { [weak self] in
                guard let self else { return }
                let joinedPacket = Data($0.joined())
                try await asyncWritePacket(joinedPacket)
            }
        }
        nwConnection.betterPathUpdateHandler = { isBetter in
            Task { [weak self] in
                await self?.onBetterPath(isBetter)
            }
        }
    }
}

// MARK: LinkInterface

extension NESocket {
    nonisolated var hasBetterPath: AsyncStream<Void> {
        betterPathStream.subscribe()
    }

    func onBetterPath(_ isBetter: Bool) {
        guard isBetter else { return }
        betterPathStream.send()
    }

    nonisolated func upgraded() -> LinkInterface {
        Self(
            queue: queue,
            nwConnection: NWConnection(
                to: nwConnection.endpoint,
                using: nwConnection.parameters
            ),
            options: options,
            remoteAddress: remoteAddress,
            remoteProtocol: remoteProtocol
        )
    }

    nonisolated func shutdown() {
        nwConnection.cancel()
    }
}

// MARK: IOInterface

extension NESocket {
    public nonisolated func setReadHandler(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
        switch options.proto.plainType {
        case .udp:
            loopReadUDPPackets(handler)
        case .tcp:
            loopReadTCPPackets(handler)
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
        guard !packets.isEmpty else {
            return
        }
        try await writeBlock?(packets)
    }
}

private extension NESocket {

    // WARNING: loops run in Network.framework queue

    nonisolated func loopReadUDPPackets(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            nwConnection.receiveMessage { [weak self] data, context, isComplete, error in
                handler(data.map { [$0] }, error)

                // repeat until failure
                if error == nil {
                    self?.loopReadUDPPackets(handler)
                }
            }
        }
    }

    nonisolated func loopReadTCPPackets(_ handler: @escaping @Sendable ([Data]?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            nwConnection.receive(
                minimumIncompleteLength: options.minLength,
                maximumLength: options.maxLength
            ) { [weak self] data, context, isComplete, error in
                handler(data.map { [$0] }, error)

                // repeat until failure
                if error == nil {
                    self?.loopReadTCPPackets(handler)
                }
            }
        }
    }

    func asyncWritePacket(_ packet: Data) async throws {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nwConnection.send(
                    content: packet,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume()
                    }
                )
            }
        } onCancel: {
            nwConnection.cancel()
        }
    }
}
