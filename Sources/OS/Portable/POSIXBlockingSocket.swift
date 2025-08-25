// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public actor POSIXBlockingSocket: SocketIOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    private var sock: pp_socket?

    private let endpoint: ExtendedEndpoint?

    private let isOwned: Bool

    private let closesOnEmptyRead: Bool

    // Synchronize manually
    nonisolated(unsafe)
    private var readBuf: [UInt8]

    public init(
        _ ctx: PartoutLoggerContext,
        endpoint: ExtendedEndpoint,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) throws {
        self.init(
            ctx: ctx,
            sock: nil,
            endpoint: endpoint,
            isOwned: true,
            closesOnEmptyRead: closesOnEmptyRead,
            maxReadLength: maxReadLength
        )
    }

    // Assumes fd to be an open socket descriptor. The socket is not
    // closed on deinit (isOwned is false).
    public init(
        _ ctx: PartoutLoggerContext,
        sock: pp_socket,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) {
        self.init(
            ctx: ctx,
            sock: sock,
            endpoint: nil,
            isOwned: false,
            closesOnEmptyRead: closesOnEmptyRead,
            maxReadLength: maxReadLength
        )
    }

    private init(
        ctx: PartoutLoggerContext,
        sock: pp_socket?,
        endpoint: ExtendedEndpoint?,
        isOwned: Bool,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) {
        precondition(sock != nil || endpoint != nil)
        self.ctx = ctx
        let queueLabelContext = sock.map { pp_socket_fd($0) }?.description ?? endpoint?.description ?? "*"
        readQueue = DispatchQueue(label: "POSIXBlockingSocket[R:\(queueLabelContext)]")
        writeQueue = DispatchQueue(label: "POSIXBlockingSocket[W:\(queueLabelContext)]")
        self.sock = sock
        self.endpoint = endpoint
        self.isOwned = isOwned
        self.closesOnEmptyRead = closesOnEmptyRead
        readBuf = [UInt8](repeating: 0, count: maxReadLength)
    }

    deinit {
        pp_log(ctx, .core, .info, "Deinit POSIXBlockingSocket")
        guard let sock, isOwned else { return }
        pp_socket_free(sock)
    }

    // Does nothing if the sock is already open and connected
    public func connect(timeout: Int) async throws {
        guard let endpoint else { return }
        guard sock == nil else {
            throw PartoutError(.linkNotActive)
        }
        let sock: pp_socket = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let sock = endpoint.address.rawValue.withCString { cAddr in
                    // Open in blocking mode
                    pp_socket_open(
                        cAddr,
                        endpoint.socketProto,
                        endpoint.proto.port,
                        true,
                        Int32(timeout)
                    )
                }
                guard let sock else {
                    continuation.resume(throwing: PartoutError(.linkNotActive))
                    return
                }
                continuation.resume(returning: sock)
            }
        }
        self.sock = sock
    }

    public func readPackets() async throws -> [Data] {
        guard let sock else {
            throw PartoutError(.linkNotActive)
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                readQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: PartoutError(.releasedObject))
                        return
                    }
                    let readCount = pp_socket_read(sock, &readBuf, readBuf.count)
                    guard readCount > 0 else {
                        if readCount == 0, closesOnEmptyRead {
                            continuation.resume(throwing: PartoutError(.linkNotActive))
                        } else {
                            continuation.resume(throwing: PartoutError(.linkFailure))
                        }
                        return
                    }
                    let newPacket = Data(readBuf[0..<Int(readCount)])
                    continuation.resume(returning: [newPacket])
                }
            }
        } catch {
            pp_log(ctx, .core, .fault, "Unable to read packets: \(error)")
            shutdown()
            throw error
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
        guard let sock else {
            throw PartoutError(.linkNotActive)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async {
                    for toWrite in packets {
                        guard !toWrite.isEmpty else { continue }
                        let writtenCount = toWrite.withUnsafeBytes {
                            pp_socket_write(sock, $0.bytePointer, toWrite.count)
                        }
                        guard writtenCount > 0 else {
                            continuation.resume(throwing: PartoutError(.linkFailure))
                            return
                        }
                    }
                    continuation.resume()
                }
            }
        } catch {
            pp_log(ctx, .core, .fault, "Unable to write packets: \(error)")
            shutdown()
            throw error
        }
    }

    public func shutdown() {
        guard let sock else { return }
        pp_log(ctx, .core, .info, "Shut down socket")
        if isOwned {
            pp_socket_free(sock)
        }
        self.sock = nil
    }
}

// XXX: Suppress warnings for safe cross-Task usage (struct is immutable)
extension pp_socket: @retroactive @unchecked Sendable {}
