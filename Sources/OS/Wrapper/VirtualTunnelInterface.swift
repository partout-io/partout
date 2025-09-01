// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if os(macOS) || os(Linux)

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class VirtualTunnelInterface: IOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private nonisolated(unsafe) let tun: pp_tun

    public nonisolated let deviceName: String

    public nonisolated let fileDescriptor: UInt64?

    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    private var readBuf: [UInt8]

    public init(_ ctx: PartoutLoggerContext, maxReadLength: Int) throws {
        guard let tun = pp_tun_open() else {
            throw PartoutError(.linkNotActive)
        }
        self.ctx = ctx
        self.tun = tun
        deviceName = String(cString: pp_tun_name(tun))
        fileDescriptor = UInt64(pp_tun_fd(tun))
        readQueue = DispatchQueue(label: "VirtualTunnelInterface[R:\(fileDescriptor!)]")
        writeQueue = DispatchQueue(label: "VirtualTunnelInterface[W:\(fileDescriptor!)]")
        readBuf = [UInt8](repeating: 0, count: maxReadLength)
    }

    deinit {
        pp_tun_free(tun)
    }

    public func readPackets() async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PartoutError(.releasedObject))
                    return
                }
                let readCount = pp_tun_read(tun, &readBuf, readBuf.count)
                guard readCount > 0 else {
                    pp_log(ctx, .core, .fault, "Unable to read TUN packets")
                    continuation.resume(throwing: PartoutError(.linkFailure))
                    return
                }
                let newPacket = Data(readBuf[0..<Int(readCount)])
                continuation.resume(returning: [newPacket])
            }
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else { return }
                for toWrite in packets {
                    guard !toWrite.isEmpty else { continue }
                    let writtenCount = toWrite.withUnsafeBytes {
                        pp_tun_write(self.tun, $0.bytePointer, toWrite.count)
                    }
                    guard writtenCount > 0 else {
                        pp_log(ctx, .core, .fault, "Unable to write TUN packets")
                        continuation.resume(throwing: PartoutError(.linkFailure))
                        return
                    }
                }
                continuation.resume()
            }
        }
    }
}

#endif
