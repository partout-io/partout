// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

// DispatchSource seems broken on Windows. Android?
#if os(macOS) || os(iOS) || os(tvOS) || os(Linux)

public actor POSIXDispatchSourceSocket: ClosingIOInterface {
    public static var isSupported: Bool {
        true
    }

    private let queue: DispatchQueue

    private var sock: pp_socket?

    private let isOwned: Bool

    private let closesOnEmptyRead: Bool

    private var readSource: DispatchSourceRead?

    private var writeSource: DispatchSourceWrite?

    private var readBuf: [UInt8]

    private var readContinuation: CheckedContinuation<[Data], Error>?

    private var writeQueue: [([Data], CheckedContinuation<Void, Error>)]

    private var isWriteResumed: Bool

    public init(
        endpoint: ExtendedEndpoint,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) throws {
        // Open in non-blocking mode
        guard let sock = endpoint.address.rawValue.withCString({ cAddr in
            pp_socket_open(cAddr, endpoint.socketProto, endpoint.proto.port, false)
        }) else {
            throw PartoutError(.linkNotActive)
        }
        self.init(
            sock,
            isOwned: true,
            closesOnEmptyRead: closesOnEmptyRead,
            maxReadLength: maxReadLength
        )
    }

    // Assumes fd to be an open socket descriptor
    public init(
        _ sock: pp_socket,
        isOwned: Bool, // Close on deinit
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) {
        /* No, you don’t have to call resume(), suspend(), or cancel() on the same queue
         * that you created the source with. GCD sources are thread-safe for those
         * methods. What matters is:
         *
         * - The event handler you provide is always invoked on the queue you assigned
         *   when creating the source.
         * - You can call resume(), suspend(), or cancel() from any thread (including
         *   from an actor or a Task).
         */
        let fd = pp_socket_fd(sock)
        let queue = DispatchQueue(label: "POSIXInterface[\(fd)]")
        let readSource = DispatchSource.makeReadSource(fileDescriptor: Int32(fd), queue: queue)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: Int32(fd), queue: queue)

        self.queue = queue
        self.sock = sock
        self.isOwned = isOwned
        self.closesOnEmptyRead = closesOnEmptyRead
        self.readSource = readSource
        self.writeSource = writeSource
        readBuf = [UInt8](repeating: 0, count: maxReadLength)
        writeQueue = []
        isWriteResumed = false

        readSource.setEventHandler { [weak self] in
            Task {
                await self?.handleReadEvent()
            }
        }
        writeSource.setEventHandler { [weak self] in
            Task {
                await self?.handleWriteEvent()
            }
        }
        readSource.resume()
    }

    deinit {
        // FIXME: ###, ctx
        pp_log_g(.core, .fault, "POSIXInterface.deinit")
        guard let sock else { return }

        // XXX: Crashes if cancelled while suspended
        if !isWriteResumed {
            writeSource?.resume()
        }
        if isOwned {
            pp_socket_free(sock)
        }
    }

    public func readPackets() async throws -> [Data] {
        guard sock != nil else { throw PartoutError(.linkNotActive) }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                readContinuation = continuation
            }
        } catch {
            // FIXME: ###, POSIXInterface logs
            pp_log(.global, .core, .fault, ">>> POSIXInterface.readPackets(): \(error)")
            shutdown()
            throw error
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
        guard sock != nil else { throw PartoutError(.linkNotActive) }
        do {
            try await withCheckedThrowingContinuation {
                writeQueue.append((packets, $0))
                resumeWriteSource(true)
            }
        } catch {
            // FIXME: ###, POSIXInterface logs
            pp_log(.global, .core, .fault, ">>> POSIXInterface.writePackets(): \(error)")
            shutdown()
            throw error
        }
    }

    public func shutdown() {
        guard let sock else { return }

        // FIXME: ###, POSIXInterface logs
        pp_log(.global, .core, .fault, ">>> POSIXInterface.close()")

        // XXX: Crashes if cancelled while suspended
        resumeWriteSource(true)

        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if isOwned {
            pp_socket_free(sock)
            self.sock = nil
        }
    }
}

private extension POSIXDispatchSourceSocket {
    func handleReadEvent() {
        guard let sock, let readContinuation else { return }
        defer {
            self.readContinuation = nil
        }
        let readCount = pp_socket_read(sock, &readBuf, readBuf.count)
        guard readCount > 0 else {
            if readCount == 0 {
                if closesOnEmptyRead {
                    readContinuation.resume(throwing: PartoutError(.linkNotActive))
                } else {
                    readContinuation.resume(returning: [])
                }
                return
            }
            // FIXME: ###
            fatalError("handleReadEvent")
            readContinuation.resume(throwing: PartoutError(.linkFailure))
            return
        }
        let packet = readBuf[0..<Int(readCount)]
        readContinuation.resume(returning: [Data(packet)])
    }

    func handleWriteEvent() {
        // FIXME: ###, POSIXInterface, many empty calls to this, can we avoid it? consumes CPU? blocking or non-blocking?
        guard let sock, !writeQueue.isEmpty else { return }
        // FIXME: ###, POSIXInterface logs
//        pp_log(.global, .core, .fault, ">>> POSIXInterface.handleWriteEvent")
        while !writeQueue.isEmpty {
            let (packets, continuation) = writeQueue.removeFirst()
            packets.forEach {
                let writtenCount = $0.withUnsafeBytes {
                    pp_socket_write(sock, $0.bytePointer, $0.count)
                }
                guard writtenCount >= 0 else {
                    // FIXME: ###
                    fatalError("handleWriteEvent")
                    continuation.resume(throwing: PartoutError(.linkFailure))
                    return
                }
            }
            continuation.resume()
        }
        resumeWriteSource(false)
    }

    func resumeWriteSource(_ doResume: Bool) {
        guard let writeSource, !writeSource.isCancelled else { return }
        if doResume {
            guard !isWriteResumed else { return }
            // FIXME: ###, POSIXInterface logs
//            pp_log(.global, .core, .fault, ">>> POSIXInterface.writeSource.resume()")
            writeSource.resume()
            isWriteResumed = true
        } else {
            guard isWriteResumed else { return }
            // FIXME: ###, POSIXInterface logs
//            pp_log(.global, .core, .fault, ">>> POSIXInterface.writeSource.suspend()")
            writeSource.suspend()
            isWriteResumed = false
        }
    }
}

#else

public final class POSIXDispatchSourceSocket: ClosingIOInterface {
    public static var isSupported: Bool {
        false
    }

    public init(
        endpoint: ExtendedEndpoint,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) throws {
        fatalError()
    }

    public func readPackets() async throws -> [Data] {
        fatalError()
    }

    public func writePackets(_ packets: [Data]) async throws {
        fatalError()
    }

    public func shutdown() async {
        fatalError()
    }
}

#endif
