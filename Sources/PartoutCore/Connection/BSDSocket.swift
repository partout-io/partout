// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A `LinkInterface` backed by dedicated blocking reader/writer loops.
public final class BSDSocket: LinkInterface, SocketIOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let endpoint: ExtendedEndpoint

    private let connectTimeout: Int

    private let closesOnEmptyRead: Bool

    private let maxReadLength: Int

    private let maxReadBatchPackets: Int

    private let maxReadBatchBytes: Int

    private let betterPathFactory: BetterPathStreamFactory

    private let betterPathStream: PassthroughStream<Void>

    private let socketHandle: SocketHandle

    private let readQueue: DispatchQueue

    private let writeQueue: DispatchQueue

    private let cleanupQueue: DispatchQueue

    private let workerGroup: DispatchGroup

    private let packetInbox: PacketInbox

    private let writeRequests: WriteRequests

    private let stateLock: SemaphoreMutex

    private var didTerminate: Bool

    public static func connect(
        _ ctx: PartoutLoggerContext,
        endpoint: ExtendedEndpoint,
        timeout: Int,
        betterPathFactory: BetterPathStreamFactory,
        socketBufferLength: Int = 1 * 1024 * 1024,
        maxReadLength: Int = 128 * 1024,
        maxReadBatchPackets: Int = 256,
        maxReadBatchBytes: Int = 256 * 1024
    ) async throws -> BSDSocket {
        let sock = try await openSocket(
            endpoint: endpoint,
            timeout: timeout,
            socketBufferLength: socketBufferLength
        )
        let closesOnEmptyRead = endpoint.plainSocketType == .tcp
        let betterPathStream = betterPathFactory.newStream()
        return BSDSocket(
            ctx: ctx,
            endpoint: endpoint,
            connectTimeout: timeout,
            sock: sock,
            closesOnEmptyRead: closesOnEmptyRead,
            maxReadLength: maxReadLength,
            maxReadBatchPackets: maxReadBatchPackets,
            maxReadBatchBytes: maxReadBatchBytes,
            betterPathFactory: betterPathFactory,
            betterPathStream: betterPathStream
        )
    }

    private init(
        ctx: PartoutLoggerContext,
        endpoint: ExtendedEndpoint,
        connectTimeout: Int,
        sock: pp_socket,
        closesOnEmptyRead: Bool,
        maxReadLength: Int,
        maxReadBatchPackets: Int,
        maxReadBatchBytes: Int,
        betterPathFactory: BetterPathStreamFactory,
        betterPathStream: PassthroughStream<Void>
    ) {
        self.ctx = ctx
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout
        self.closesOnEmptyRead = closesOnEmptyRead
        self.maxReadLength = maxReadLength
        self.maxReadBatchPackets = max(1, maxReadBatchPackets)
        self.maxReadBatchBytes = max(maxReadLength, maxReadBatchBytes)
        self.betterPathFactory = betterPathFactory
        self.betterPathStream = betterPathStream
        socketHandle = SocketHandle(sock: sock)
        let queueLabelContext = socketHandle.fileDescriptor?.description ?? "unknown"
        readQueue = DispatchQueue(
            label: "BSDSocket[R:\(queueLabelContext)]",
            qos: .userInitiated
        )
        writeQueue = DispatchQueue(
            label: "BSDSocket[W:\(queueLabelContext)]",
            qos: .userInitiated
        )
        cleanupQueue = DispatchQueue(
            label: "BSDSocket[C:\(queueLabelContext)]",
            qos: .utility
        )
        workerGroup = DispatchGroup()
        packetInbox = PacketInbox()
        writeRequests = WriteRequests()
        stateLock = SemaphoreMutex()
        didTerminate = false

        workerGroup.enter()
        readQueue.async(execute: readLoop)
        workerGroup.enter()
        writeQueue.async(execute: writeLoop)
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit BSDSocket")
    }

    public nonisolated var remoteAddress: String {
        endpoint.address.rawValue
    }

    public nonisolated var remoteProtocol: EndpointProtocol {
        endpoint.proto
    }

    public nonisolated var hasBetterPath: AsyncStream<Void> {
        betterPathStream.subscribe()
    }

    public nonisolated var fileDescriptor: UInt64? {
        socketHandle.fileDescriptor
    }

    public func readPackets() async throws -> [Data] {
        try await packetInbox.pop()
    }

    public func writePackets(_ packets: [Data]) async throws {
        guard !packets.isEmpty else { return }
        try await writeRequests.enqueue(packets)
    }

    @available(*, deprecated)
    public func setReadHandler(_ handler: @escaping ([Data]?, (any Error)?) -> Void) {
        fatalError("Deprecated")
    }

    public func upgraded() async throws -> LinkInterface {
        try await Self.connect(
            ctx,
            endpoint: endpoint,
            timeout: connectTimeout,
            betterPathFactory: betterPathFactory,
            maxReadLength: maxReadLength
        )
    }

    public nonisolated func shutdown() {
        terminate(with: PartoutError(.linkNotActive))
    }
}

private extension BSDSocket {
    static func openSocket(
        endpoint: ExtendedEndpoint,
        timeout: Int,
        socketBufferLength: Int
    ) async throws -> pp_socket {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let blocking = endpoint.plainSocketType == .tcp
                let newSock = endpoint.address.rawValue.withCString { cAddr in
                    pp_socket_open(
                        cAddr,
                        endpoint.socketProto,
                        endpoint.proto.port,
                        blocking,
                        Int32(timeout)
                    )
                }
                guard let newSock else {
                    continuation.resume(throwing: PartoutError(.linkNotActive))
                    return
                }
                _ = pp_socket_set_buffers(
                    newSock,
                    Int32(socketBufferLength),
                    Int32(socketBufferLength)
                )
                continuation.resume(returning: newSock)
            }
        }
    }

    @Sendable
    func readLoop() {
        defer {
            workerGroup.leave()
        }
        switch endpoint.plainSocketType {
        case .udp:
            readLoopUDP()
        case .tcp:
            readLoopTCP()
        }
    }

    @Sendable
    func writeLoop() {
        defer {
            workerGroup.leave()
        }
        switch endpoint.plainSocketType {
        case .udp:
            writeLoopUDP()
        case .tcp:
            writeLoopTCP()
        }
    }

    func readLoopUDP() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReadLength)
        defer {
            buffer.deallocate()
        }

        while true {
            guard pp_socket_wait_readable(socketHandle.sock, -1) else {
                terminate(with: socketHandle.preferredError())
                return
            }

            var packets: [Data] = []
            packets.reserveCapacity(maxReadBatchPackets)
            var batchBytes = 0

            while packets.count < maxReadBatchPackets, batchBytes < maxReadBatchBytes {
                let readCount = pp_socket_read(socketHandle.sock, buffer, maxReadLength)

                // Would-block is expected while draining, but not as the first read after readiness.
                guard readCount != PP_SOCKET_WOULD_BLOCK else {
                    if packets.isEmpty {
                        terminate(with: socketHandle.preferredError())
                        return
                    }
                    break
                }

                // Failure if < 0
                guard readCount >= 0 else {
                    if !packets.isEmpty {
                        packetInbox.push(packets)
                    }
                    terminate(with: socketHandle.preferredError())
                    return
                }
                // Non-blocking read
                guard readCount != 0 else {
                    if socketHandle.isStopping {
                        if !packets.isEmpty {
                            packetInbox.push(packets)
                        }
                        return
                    }
                    break
                }

                packets.append(Data(bytes: buffer, count: Int(readCount)))
                batchBytes += Int(readCount)
            }

            guard !packets.isEmpty else { continue }
            packetInbox.push(packets)
        }
    }

    func writeLoopUDP() {
        while let request = writeRequests.next() {
            for packet in request.packets {
                guard !packet.isEmpty else { continue }
                var error: Error?
                while true {
                    guard pp_socket_wait_writable(socketHandle.sock, -1) else {
                        error = socketHandle.preferredError()
                        break
                    }
                    let writtenCount = packet.withUnsafeBytes { ptr -> Int in
                        guard let baseAddress = ptr.bindMemory(to: UInt8.self).baseAddress else {
                            return 0
                        }
                        return Int(pp_socket_write(socketHandle.sock, baseAddress, packet.count))
                    }
                    // Non-blocking write
                    guard writtenCount != PP_SOCKET_WOULD_BLOCK else {
                        if socketHandle.isStopping {
                            let error = socketHandle.preferredError()
                            request.continuation.resume(throwing: error)
                            return
                        }
                        error = socketHandle.preferredError()
                        break
                    }
                    guard writtenCount != 0 else {
                        continue
                    }

                    // Report failure unless packet was written fully
                    if writtenCount != packet.count {
                        error = socketHandle.preferredError()
                    }
                    break
                }
                if let error {
                    request.continuation.resume(throwing: error)
                    terminate(with: error)
                    return
                }
            }
            request.continuation.resume()
        }
    }

    func readLoopTCP() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReadLength)
        defer {
            buffer.deallocate()
        }

        // TCP should imply that this is true
        assert(closesOnEmptyRead)

        while true {
            let readCount = pp_socket_read(socketHandle.sock, buffer, maxReadLength)
            guard readCount > 0 else {
                let error = socketHandle.preferredError(withReadCount: readCount)
                terminate(with: error)
                return
            }

            var packets: [Data] = []
            packets.reserveCapacity(maxReadBatchPackets)
            var batchBytes = 0

            packets.append(Data(bytes: buffer, count: Int(readCount)))
            batchBytes += Int(readCount)

            while packets.count < maxReadBatchPackets,
                  batchBytes < maxReadBatchBytes,
                  pp_socket_wait_readable(socketHandle.sock, 0) {
                let nextReadCount = pp_socket_read(socketHandle.sock, buffer, maxReadLength)
                guard nextReadCount > 0 else {
                    let error = socketHandle.preferredError(withReadCount: nextReadCount)
                    packetInbox.push(packets)
                    terminate(with: error)
                    return
                }
                packets.append(Data(bytes: buffer, count: Int(nextReadCount)))
                batchBytes += Int(nextReadCount)
            }

            packetInbox.push(packets)
        }
    }

    func writeLoopTCP() {
        while let request = writeRequests.next() {
            for packet in request.packets {
                guard !packet.isEmpty else { continue }
                let writtenCount = packet.withUnsafeBytes { ptr -> Int in
                    guard let baseAddress = ptr.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return Int(pp_socket_write(socketHandle.sock, baseAddress, packet.count))
                }
                guard writtenCount > 0 else {
                    let error = socketHandle.preferredError()
                    request.continuation.resume(throwing: error)
                    terminate(with: error)
                    return
                }
            }
            request.continuation.resume()
        }
    }

    func terminate(with error: Error) {
        let shouldTerminate: Bool
        stateLock.lock()
        shouldTerminate = !didTerminate
        if shouldTerminate {
            didTerminate = true
        }
        stateLock.unlock()

        guard shouldTerminate else {
            return
        }

        pp_log(ctx, .core, .info, "Terminate BSD socket: \(error)")
        socketHandle.requestShutdown()
        packetInbox.finish(throwing: error)
        writeRequests.finish(throwing: error)
        betterPathStream.finish()

        cleanupQueue.async { [socketHandle, workerGroup] in
            workerGroup.wait()
            socketHandle.close()
        }
    }
}

// MARK: - Helpers

private extension BSDSocket {
    struct WriteRequest {
        let packets: [Data]

        let continuation: CheckedContinuation<Void, Error>
    }

    final class PacketInbox: @unchecked Sendable {
        private enum ImmediatePop {
            case packets([Data])

            case failure(Error)

            case wait
        }

        private let lock: SemaphoreMutex

        private var bufferedPackets: FIFO<[Data]>

        private var waitingContinuation: CheckedContinuation<[Data], Error>?

        private var terminalError: Error?

        init() {
            lock = SemaphoreMutex()
            bufferedPackets = FIFO()
        }

        func push(_ packets: [Data]) {
            guard !packets.isEmpty else {
                return
            }

            let continuation: CheckedContinuation<[Data], Error>?
            lock.lock()
            if terminalError != nil {
                lock.unlock()
                return
            }
            continuation = waitingContinuation
            waitingContinuation = nil
            if continuation == nil {
                bufferedPackets.append(packets)
            }
            lock.unlock()

            continuation?.resume(returning: packets)
        }

        func finish(throwing error: Error) {
            let continuation: CheckedContinuation<[Data], Error>?
            lock.lock()
            guard terminalError == nil else {
                lock.unlock()
                return
            }
            terminalError = error
            continuation = waitingContinuation
            waitingContinuation = nil
            bufferedPackets.removeAll()
            lock.unlock()

            continuation?.resume(throwing: error)
        }

        func pop() async throws -> [Data] {
            switch immediatePop() {
            case .packets(let packets):
                return packets
            case .failure(let error):
                throw error
            case .wait:
                return try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if let packets = bufferedPackets.popFirst() {
                        lock.unlock()
                        continuation.resume(returning: packets)
                        return
                    }
                    if let terminalError {
                        lock.unlock()
                        continuation.resume(throwing: terminalError)
                        return
                    }
                    precondition(waitingContinuation == nil, "Concurrent reads are unsupported")
                    waitingContinuation = continuation
                    lock.unlock()
                }
            }
        }

        private func immediatePop() -> ImmediatePop {
            lock.lock()
            defer {
                lock.unlock()
            }
            if let packets = bufferedPackets.popFirst() {
                return .packets(packets)
            }
            if let terminalError {
                return .failure(terminalError)
            }
            return .wait
        }
    }

    final class WriteRequests: @unchecked Sendable {
        private let lock: SemaphoreMutex

        private let semaphore: DispatchSemaphore

        private var requests: FIFO<WriteRequest>

        private var terminalError: Error?

        init() {
            lock = SemaphoreMutex()
            semaphore = DispatchSemaphore(value: 0)
            requests = FIFO()
        }

        func enqueue(_ packets: [Data]) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let terminalError {
                    lock.unlock()
                    continuation.resume(throwing: terminalError)
                    return
                }
                requests.append(
                    WriteRequest(
                        packets: packets,
                        continuation: continuation
                    )
                )
                lock.unlock()
                semaphore.signal()
            }
        }

        func next() -> WriteRequest? {
            while true {
                semaphore.wait()

                lock.lock()
                if let request = requests.popFirst() {
                    lock.unlock()
                    return request
                }
                let shouldStop = terminalError != nil
                lock.unlock()

                if shouldStop {
                    return nil
                }
            }
        }

        func finish(throwing error: Error) {
            let pending: [WriteRequest]
            lock.lock()
            guard terminalError == nil else {
                lock.unlock()
                return
            }
            terminalError = error
            pending = requests.removeAllElements()
            lock.unlock()

            for request in pending {
                request.continuation.resume(throwing: error)
            }
            semaphore.signal()
        }
    }

    struct FIFO<Element> {
        private var storage: [Element?]

        private var head: Int

        init() {
            storage = []
            head = 0
        }

        mutating func append(_ element: Element) {
            storage.append(element)
        }

        mutating func popFirst() -> Element? {
            guard head < storage.count, let element = storage[head] else {
                return nil
            }
            storage[head] = nil
            head += 1
            if head >= 64, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return element
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: true)
            head = 0
        }

        mutating func removeAllElements() -> [Element] {
            let elements = storage[head...].compactMap {
                $0
            }
            removeAll()
            return elements
        }
    }
}

private extension ExtendedEndpoint {
    var plainSocketType: SocketType {
        proto.socketType.plainType
    }
}

private extension SocketHandle {
    func preferredError() -> PartoutError {
        isStopping ? PartoutError(.linkNotActive) : PartoutError(.ioFailure)
    }

    func preferredError(withReadCount readCount: Int32) -> PartoutError {
        // In non-blocking TCP, "0 bytes" means "link inactive"
        isStopping || readCount == 0 ? PartoutError(.linkNotActive) : PartoutError(.ioFailure)
    }
}
