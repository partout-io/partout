// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(iOS) && !os(tvOS)

import Foundation
import PartoutCore_C

public final class VirtualTunnelInterface: IOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let tun: pp_tun

    public let tunImpl: UnsafeMutableRawPointer?

    public nonisolated let deviceName: String?

    public nonisolated let fileDescriptor: UInt64?

    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    // FIXME: #188, how to avoid silent copy? (enforce reference)
    private var readBuf: [UInt8]

    public init(_ ctx: PartoutLoggerContext, uuid: UniqueID, tunImpl: UnsafeMutableRawPointer?, maxReadLength: Int) throws {
        guard let tun = uuid.uuidString.withCString({
            pp_tun_create($0, tunImpl)
        }) else {
            throw PartoutError(.linkNotActive)
        }
        self.ctx = ctx
        self.tun = tun
        self.tunImpl = tunImpl
        if let tunName = pp_tun_name(tun) {
            deviceName = String(cString: tunName)
        } else {
            deviceName = nil
        }
        let fd = pp_tun_fd(tun)
        fileDescriptor = fd >= 0 ? UInt64(fd) : nil
        // FIXME: #188, Windows has device name but it's wchar_t *
        let label = deviceName?.description ?? fileDescriptor?.description ?? "*"
        readQueue = DispatchQueue(label: "VirtualTunnelInterface[R:\(label)]")
        writeQueue = DispatchQueue(label: "VirtualTunnelInterface[W:\(label)]")
        readBuf = [UInt8](repeating: 0, count: maxReadLength)
    }

    deinit {
        pp_log(ctx, .core, .info, "Deinit VirtualTunnelInterface")
        pp_tun_free(tun)
    }

    public func readPackets() async throws -> [Data] {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                readQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: PartoutError(.releasedObject))
                        return
                    }
                    let readCount = pp_tun_read(tun, &readBuf, readBuf.count)
                    guard readCount > 0 else {
                        continuation.resume(throwing: PartoutError(.linkFailure))
                        return
                    }
                    let newPacket = Data(readBuf[0..<Int(readCount)])
                    continuation.resume(returning: [newPacket])
                }
            }
        } catch {
            pp_log(ctx, .core, .fault, "Unable to read TUN packets: \(error)")
            throw error
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async { [weak self] in
                    guard let self else { return }
                    for toWrite in packets {
                        guard !toWrite.isEmpty else { continue }
                        let writtenCount = toWrite.withUnsafeBytes {
                            pp_tun_write(self.tun, $0.bytePointer, toWrite.count)
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
            pp_log(ctx, .core, .fault, "Unable to write TUN packets: \(error)")
            throw error
        }
    }
}

#endif
