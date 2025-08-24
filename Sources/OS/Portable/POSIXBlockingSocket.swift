// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class POSIXBlockingSocket: ClosingIOInterface, @unchecked Sendable {
    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    private var sock: pp_socket?

    private let isOwned: Bool

    private let closesOnEmptyRead: Bool

    private var readBuf: [UInt8]

    public convenience init(
        endpoint: ExtendedEndpoint,
        closesOnEmptyRead: Bool,
        maxReadLength: Int
    ) throws {
        // Open in blocking mode
        guard let sock = endpoint.address.rawValue.withCString({ cAddr in
            pp_socket_open(cAddr, endpoint.socketProto, endpoint.proto.port, true)
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
        readQueue = DispatchQueue(label: "POSIXBlockingSocket[R:\(pp_socket_fd(sock))]")
        writeQueue = DispatchQueue(label: "POSIXBlockingSocket[W:\(pp_socket_fd(sock))]")
        self.sock = sock
        self.isOwned = isOwned
        self.closesOnEmptyRead = closesOnEmptyRead
        readBuf = [UInt8](repeating: 0, count: maxReadLength)
    }

    deinit {
        guard let sock else { return }
        if isOwned {
            // FIXME: ###, does this interrupt recv/send?
            pp_socket_free(sock)
        }
    }

    public func readPackets() async throws -> [Data] {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                readQueue.async { [weak self] in
                    // FIXME: ###
                    let rnd = pp_prng_rand()
                    guard let self, let sock else {
                        continuation.resume(throwing: PartoutError(.linkNotActive))
                        return
                    }
                    pp_log_g(.core, .error, ">>> readPackets() [\(rnd)]")
                    let readCount = pp_socket_read(sock, &readBuf, readBuf.count)
                    pp_log_g(.core, .error, ">>> readPackets() [\(rnd)]: \(readCount)")
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
            // FIXME: ###, POSIXInterface logs
//            pp_log(.global, .core, .fault, ">>> POSIXInterface.readPackets(): \(error)")
            shutdown()
            throw error
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async { [weak self] in
                    // FIXME: ###
                    guard let self, let sock else {
                        continuation.resume(throwing: PartoutError(.linkNotActive))
                        return
                    }
                    for toWrite in packets {
                        guard !toWrite.isEmpty else { continue }
                        let rnd = pp_prng_rand()
                        pp_log_g(.core, .error, ">>> writePackets() [\(rnd)]")
                        let writtenCount = toWrite.withUnsafeBytes {
                            pp_socket_write(sock, $0.bytePointer, toWrite.count)
                        }
                        pp_log_g(.core, .error, ">>> writePackets(): \(rnd)")
                        guard writtenCount > 0 else {
                            continuation.resume(throwing: PartoutError(.linkFailure))
                            return
                        }
                    }
                    continuation.resume()
                }
            }
        } catch {
            // FIXME: ###, POSIXInterface logs
//            pp_log(.global, .core, .fault, ">>> POSIXInterface.writePackets(): \(error)")
            shutdown()
            throw error
        }
    }

    public func shutdown() {
        readQueue.sync { [weak self] in
            self?.writeQueue.sync { [weak self] in
                guard let self, let sock else { return }
                // FIXME: ###, POSIXInterface logs
//                pp_log(.global, .core, .fault, ">>> POSIXInterface.close()")
                if isOwned {
                    pp_socket_free(sock)
                    self.sock = nil
                }
            }
        }
    }
}
