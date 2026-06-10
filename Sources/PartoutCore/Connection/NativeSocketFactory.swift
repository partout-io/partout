// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

public final class NativeSocketFactory: NetworkInterfaceFactory {
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
        NativeSocketObserver(
            ctx,
            betterPathFactory: betterPathFactory,
            configurator: configurator,
            bufSize: bufSize,
            endpoint: endpoint
        )
    }
}

final class NativeSocketObserver: LinkObserver {
    private let ctx: PartoutLoggerContext
    private let betterPathFactory: BetterPathStreamFactory
    private let configurator: SocketConfigurator?
    private let bufSize: Int
    private let endpoint: ExtendedEndpoint

    init(
        _ ctx: PartoutLoggerContext,
        betterPathFactory: BetterPathStreamFactory,
        configurator: SocketConfigurator?,
        bufSize: Int,
        endpoint: ExtendedEndpoint
    ) {
        self.ctx = ctx
        self.betterPathFactory = betterPathFactory
        self.configurator = configurator
        self.bufSize = bufSize
        self.endpoint = endpoint
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit NativeSocketObserver")
    }

    func waitForActivity(timeout: Int) async throws -> LinkInterface {
        try await SocketWrapper(
            ctx,
            options: SocketWrapper.Options(
                endpoint: endpoint,
                timeout: timeout,
                bufSize: bufSize,
                configurator: configurator,
                betterPathStream: betterPathFactory.newStream()
            )
        )
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
#if os(Windows)
    private let handle: FileDescriptor
#endif
    private var isClosed = false

    init(_ ctx: PartoutLoggerContext, options: Options) async throws {
        let socket: pp_socket = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Socket properties
                let proto = options.endpoint.socketProto
                let port = options.endpoint.proto.port
                let blocking = false

                // Configurator
                let reachability = options.configurator?.reachability()
                var cReachability = pp_reachability()
                cReachability.reachable = reachability?.isReachable ?? false
#if os(Android)
                cReachability.network_handle = reachability?.networkHandle ?? 0
#endif
                let cConfigurator = options.configurator.map {
                    Unmanaged.passUnretained($0).toOpaque()
                }

                let newSock = options.endpoint.address.rawValue.withCString { cAddr in
                    pp_socket_open(
                        cAddr,
                        proto,
                        port,
                        blocking,
                        Int32(options.timeout),
                        &cReachability,
                        { ctx, fd in
                            guard let ctx else { return true }
                            let cfg = Unmanaged<SocketConfigurator>
                                .fromOpaque(ctx)
                                .takeUnretainedValue()
                            return cfg.configureSocket(fd)
                        },
                        cConfigurator
                    )
                }
                guard let newSock else {
                    continuation.resume(throwing: PartoutError(.linkNotActive))
                    return
                }
                _ = pp_socket_set_buffers(
                    newSock,
                    Int32(options.bufSize),
                    Int32(options.bufSize)
                )
                continuation.resume(returning: newSock)
            }
        }
#if os(Windows)
        let handle = WSACreateEvent()
        do {
            guard let handle else {
                throw PartoutError(.fdUnavailable)
            }
            guard WSAEventSelect(
                pp_socket_get_fd(socket),
                handle,
                FD_READ | FD_WRITE | FD_CLOSE
            ) == 0 else {
                throw PartoutError(.linkNotActive)
            }
        } catch {
            if let handle {
                WSACloseEvent(handle)
            }
            pp_socket_free(socket)
            throw error
        }
        self.handle = handle
#endif
        self.ctx = ctx
        self.socket = socket
        self.options = options
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit SocketWrapper")
#if os(Windows)
        WSACloseEvent(handle)
#endif
        cleanup()
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
#if os(Windows)
        handle
#else
        pp_socket_get_fd(socket)
#endif
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
