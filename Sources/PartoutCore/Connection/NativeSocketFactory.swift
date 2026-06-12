// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

public final class NativeSocketFactory: NetworkInterfaceFactory {
    private struct Observer: LinkObserver {
        let factory: NativeSocketFactory
        let endpoint: ExtendedEndpoint

        func waitForActivity(timeout: Int) async throws -> LinkInterface {
            try await SocketWrapper(
                factory.ctx,
                options: SocketWrapper.Options(
                    endpoint: endpoint,
                    timeout: timeout,
                    bufSize: factory.bufSize,
                    configurator: factory.configurator,
                    betterPathStream: factory.betterPathFactory.newStream()
                )
            )
        }
    }

    private let ctx: PartoutLoggerContext
    private let betterPathFactory: BetterPathStreamFactory
    private let configurator: SocketConfigurator?
    private let bufSize: Int

    public init(
        _ ctx: PartoutLoggerContext,
        betterPathFactory: BetterPathStreamFactory,
        configurator: SocketConfigurator? = nil,
        bufSize: Int = 1 * 1024 * 1024, // 1MB
    ) {
        self.ctx = ctx
        self.betterPathFactory = betterPathFactory
        self.configurator = configurator
        self.bufSize = bufSize
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit NativeSocketFactory")
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        Observer(factory: self, endpoint: endpoint)
    }
}

final class SocketWrapper: NativeIOInterface, @unchecked Sendable {
    struct Options: Sendable {
        let endpoint: ExtendedEndpoint
        let timeout: Int
        let bufSize: Int
        let configurator: SocketConfigurator?
        let betterPathStream: PassthroughStream<Void>
    }

    private let ctx: PartoutLoggerContext
    let socket: pp_socket
    private let options: Options
    private var isClosed = false

    init(_ ctx: PartoutLoggerContext, options: Options) async throws {
        let socket: pp_socket = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let newSocket = Self.openSocket(withOptions: options) else {
                    continuation.resume(throwing: PartoutError(.linkNotActive))
                    return
                }
                continuation.resume(returning: newSocket)
            }
        }
        self.ctx = ctx
        self.socket = socket
        self.options = options
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit SocketWrapper")
        cleanup()
    }

    func setEventMask(read: Bool, write: Bool) throws {
        guard pp_socket_set_event_mask(socket, read, write) else {
            throw PartoutError(.ioFailure)
        }
    }

    func resetEvents() throws {
        guard pp_socket_reset_events(socket) else {
            throw PartoutError(.ioFailure)
        }
    }

    func read(_ buf: inout [UInt8]) -> Int32 {
        pp_socket_read(socket, &buf, buf.count)
    }

    func write(_ data: Data, offset: Int) -> Int32 {
        let count = data.count - offset
        return data.withUnsafeBytes {
            pp_socket_write(
                socket,
                $0.bytePointer + offset,
                count
            )
        }
    }

    func cleanup() {
        guard !isClosed else { return }
        isClosed = true
        pp_socket_free(socket)
    }

    var lastErrorCode: Int32 {
        pp_socket_last_error()
    }
}

extension SocketWrapper: LinkInterface {
    var muxDescriptor: FileDescriptor? {
        let fd = pp_socket_get_watch_fd(socket)
        guard pp_fd_is_valid(fd) else { return nil }
        return fd
    }

    var nativeIO: NativeIOInterface? {
        self
    }

    var remoteAddress: String {
        options.endpoint.address.rawValue
    }

    var remoteProtocol: EndpointProtocol {
        options.endpoint.proto
    }

    var hasBetterPath: AsyncStream<Void> {
        options.betterPathStream.subscribe()
    }

    func upgraded() async throws -> LinkInterface {
        try await SocketWrapper(ctx, options: options)
    }

    func close() {
        guard !isClosed else { return }
        pp_socket_close(socket)
    }

    func readPackets() async throws -> [Data] {
        fatalError("Not implemented")
    }

    func writePackets(_ packets: [Data]) async throws {
        fatalError("Not implemented")
    }
}

// MARK: - C socket creation

private extension SocketWrapper {
    static func openSocket(withOptions options: Options) -> pp_socket? {
        let proto = options.endpoint.socketProto
        let port = options.endpoint.proto.port

        // WARNING: Non-blocking mode is crucial to work with FdLooper
        let blocking = false

        // Fetch current reachability
        let reachability = options.configurator?.reachability()
        var cReachability = reachability?.toCReachability ?? pp_reachability_none()

        // Run the configurator right after socket creation
        let cConfigure: pp_socket_configure?
        let cConfigurator: UnsafeMutableRawPointer?
        if let configurator = options.configurator {
            cConfigure = { ctx, fd in
                guard let ctx else { return true }
                let cfg = Unmanaged<SocketConfigurator>
                    .fromOpaque(ctx)
                    .takeUnretainedValue()
                return cfg.configureSocket(fd)
            }
            cConfigurator = Unmanaged.passUnretained(configurator).toOpaque()
        } else {
            cConfigure = nil
            cConfigurator = nil
        }

        // Open a connected socket
        let socket = options.endpoint.address.rawValue.withCString { cAddress in
            pp_socket_open(
                cAddress,
                proto,
                port,
                blocking,
                Int32(options.timeout),
                &cReachability,
                cConfigure,
                cConfigurator
            )
        }
        guard let socket else {
            return nil
        }
        _ = pp_socket_set_buffers(
            socket,
            Int32(options.bufSize),
            Int32(options.bufSize)
        )
        return socket
    }
}
