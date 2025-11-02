// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore_C

/// An ``IOInterface`` based on a POSIX socket with blocking I/O.
public actor POSIXBlockingSocket: SocketIOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    nonisolated(unsafe)
    private let sock: pp_socket

    private let endpoint: ExtendedEndpoint?

    private let closesOnEmptyRead: Bool

    // FIXME: #188, how to avoid silent copy? (enforce reference)
    nonisolated(unsafe)
    private var readBuf: [UInt8]

    private var isActive = false

    public init(
        _ ctx: PartoutLoggerContext,
        to endpoint: ExtendedEndpoint,
        timeout: Int,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) throws {
        let newSock = endpoint.address.rawValue.withCString { cAddr in
            // Open in blocking mode
            pp_socket_open(
                cAddr,
                endpoint.socketProto,
                endpoint.proto.port,
                true,
                Int32(timeout)
            )
        }
        guard let newSock else {
            throw PartoutError(.linkNotActive)
        }
        self.init(
            ctx: ctx,
            sock: newSock,
            endpoint: endpoint,
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
            closesOnEmptyRead: closesOnEmptyRead,
            maxReadLength: maxReadLength
        )
    }

    private init(
        ctx: PartoutLoggerContext,
        sock: pp_socket,
        endpoint: ExtendedEndpoint?,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) {
        self.ctx = ctx
        let queueLabelContext = pp_socket_fd(sock).description
        readQueue = DispatchQueue(label: "POSIXBlockingSocket[R:\(queueLabelContext)]")
        writeQueue = DispatchQueue(label: "POSIXBlockingSocket[W:\(queueLabelContext)]")
        self.sock = sock
        self.endpoint = endpoint
        self.closesOnEmptyRead = closesOnEmptyRead
        readBuf = [UInt8](repeating: 0, count: maxReadLength)
        isActive = true
    }

    deinit {
        pp_log(ctx, .core, .info, "Deinit POSIXBlockingSocket")
        pp_socket_free(sock)
    }

    public nonisolated var fileDescriptor: UInt64? {
        pp_socket_fd(sock)
    }

    public func readPackets() async throws -> [Data] {
        guard isActive else {
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
        guard isActive else {
            throw PartoutError(.linkNotActive)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async { [weak self] in
                    guard let sock = self?.sock else { return }
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
        guard isActive else { return }
        isActive = false
        pp_log(ctx, .core, .info, "Shut down socket")
        pp_socket_free(sock)
    }
}
