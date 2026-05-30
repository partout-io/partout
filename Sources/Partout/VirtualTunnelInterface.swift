// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// An interface that interacts with a Layer 3 virtual tun device, commonly found in UNIX-like systems.
final class VirtualTunnelInterface: SocketIOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    let tun: pp_tun

    nonisolated let deviceName: String?

    private let descriptor: UInt64?

    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    // FIXME: #188, how to avoid silent copy? (enforce reference)
    private var readBuf: [UInt8]

    private var isActive: Bool {
        get {
            activeLock.lock()
            defer { activeLock.unlock() }
            return _isActive
        }
        set {
            activeLock.lock()
            defer { activeLock.unlock() }
            _isActive = newValue
        }
    }

    private var _isActive: Bool

    private let activeLock: SemaphoreMutex

    // WARNING: tun ownership is transferred
    init(
        _ ctx: PartoutLoggerContext,
        tun: pp_tun,
        maxReadLength: Int
    ) {
        self.ctx = ctx
        self.tun = tun
        if let tunName = pp_tun_name(tun) {
            deviceName = String(cString: tunName)
        } else {
            deviceName = nil
        }
        let fd = pp_tun_fd(tun)
        descriptor = fd >= 0 ? UInt64(fd) : nil
        // FIXME: #188, Windows has device name but it's wchar_t *
        let label = deviceName?.description ?? descriptor?.description ?? "*"
        readQueue = DispatchQueue(label: "VirtualTunnelInterface[R:\(label)]")
        writeQueue = DispatchQueue(label: "VirtualTunnelInterface[W:\(label)]")
        readBuf = [UInt8](repeating: 0, count: maxReadLength)

        _isActive = true
        activeLock = SemaphoreMutex()
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit VirtualTunnelInterface")
    }

    nonisolated var fileDescriptor: UInt64? {
        isActive ? descriptor : nil
    }

    func readPackets() async throws -> [Data] {
        guard isActive else {
            throw PartoutError(.tunNotActive)
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                readQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: PartoutError(.releasedObject))
                        return
                    }
                    guard self.isActive else {
                        continuation.resume(throwing: PartoutError(.tunNotActive))
                        return
                    }
                    let readCount = pp_tun_read(tun, &readBuf, readBuf.count)
                    guard readCount > 0 else {
                        guard errno != EAGAIN else {
                            continuation.resume(returning: [])
                            return
                        }
                        continuation.resume(throwing: PartoutError(.linkFailure))
                        return
                    }
                    let newPacket = Data(readBuf[0..<Int(readCount)])
                    continuation.resume(returning: [newPacket])
                }
            }
        } catch {
            guard isActive else {
                throw PartoutError(.tunNotActive)
            }
            pp_log(ctx, .core, .fault, "Unable to read TUN packets: \(error)")
            await shutdown()
            throw error
        }
    }

    func writePackets(_ packets: [Data]) async throws {
        guard isActive else {
            throw PartoutError(.tunNotActive)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: PartoutError(.releasedObject))
                        return
                    }
                    guard self.isActive else {
                        continuation.resume(throwing: PartoutError(.tunNotActive))
                        return
                    }
                    for toWrite in packets {
                        guard !toWrite.isEmpty else { continue }
                        guard self.isActive else {
                            continuation.resume(throwing: PartoutError(.tunNotActive))
                            return
                        }
                        let writtenCount = toWrite.withUnsafeBytes {
                            pp_tun_write(self.tun, $0.bytePointer, toWrite.count)
                        }
                        guard writtenCount > 0 else {
                            guard errno != EAGAIN else {
                                continuation.resume()
                                return
                            }
                            continuation.resume(throwing: PartoutError(.linkFailure))
                            return
                        }
                    }
                    continuation.resume()
                }
            }
        } catch {
            guard isActive else {
                throw PartoutError(.tunNotActive)
            }
            pp_log(ctx, .core, .fault, "Unable to write TUN packets: \(error)")
            await shutdown()
            throw error
        }
    }

    func shutdown() async {
        let shouldShutdown: Bool
        activeLock.lock()
        shouldShutdown = _isActive
        _isActive = false
        activeLock.unlock()
        guard shouldShutdown else { return }
        pp_log(ctx, .core, .info, "Shut down TUN")
        pp_tun_shutdown(tun)
    }

    func waitUntilIdle() async {
        await readQueue.waitUntilIdle()
        await writeQueue.waitUntilIdle()
    }
}

private extension DispatchQueue {
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            `async` {
                continuation.resume()
            }
        }
    }
}
