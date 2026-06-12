// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A ``TunnelController`` that interacts with a tun interface through the native platform.
public final class NativeTunnelController: TunnelController, Sendable {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let ref: UnsafeMutableRawPointer?

    private let environment: TunnelEnvironmentReader

    private let bufSize: Int

    private let onReachableStream: CurrentValueStream<Bool>

    private let reachabilityHolder: ReachabilityHolder

    private let betterPathProxy: BetterPathProxy

    private let dns: DNSResolver

    public init(
        _ ctx: PartoutLoggerContext,
        ref: UnsafeMutableRawPointer?,
        environment: TunnelEnvironmentReader,
        bufSize: Int = 1 * 1024 * 1024 // 1MB
    ) throws {
        self.ctx = ctx
#if os(Android)
        pp_log(ctx, .core, .debug, "NativeTunnelController: Retain JNI ref")
        guard let retainedRef = pp_jni_new_global_ref(ref) else {
            throw PartoutError(.releasedObject)
        }
        self.ref = retainedRef
#else
        self.ref = ref
#endif
        self.environment = environment
        self.bufSize = bufSize
        onReachableStream = CurrentValueStream(false)
        reachabilityHolder = ReachabilityHolder()
        betterPathProxy = BetterPathProxy()

        // Native resolver requires network handle on Android
        dns = SimpleDNSResolver {
            POSIXDNSStrategy(hostname: $0, flags: $1)
        }

        var delegate = pp_tun_ctrl_delegate(
            ctx: .fromSelf(self),
            on_reachability: { ctx, reachability in
                let this = ctx.toSelf
                this.onReachability(reachability)
            },
            on_better_path: { ctx in
                let this = ctx.toSelf
                this.onBetterPath()
            },
            environment_value: { ctx, key in
                let this = ctx.toSelf
                guard let data = this.environmentData(forKey: String(cString: key)),
                      let json = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return pp_dup(json)
            }
        )
        pp_tun_ctrl_set_delegate(self.ref, &delegate)
    }

    deinit {
        pp_tun_ctrl_set_delegate(ref, nil)
        pp_log(ctx, .core, .debug, "Deinit NativeTunnelController")
#if os(Android)
        pp_log(ctx, .core, .debug, "NativeTunnelController: Release JNI ref")
        pp_jni_delete_global_ref(ref)
#endif
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> TunInterface {
        guard let info else {
            throw PartoutError(.notFound)
        }
        guard info.requiresVirtualDevice else {
            return DummyTunnelInterface()
        }

        // Encode to JSON for native receivers
        let infoJSON = try info.encodedAsJSON()

        // Create tun with optional implementation from controller
        guard let tun = info.originalModuleId.uuidString.withCString({ uuid in
            infoJSON.withCString { info in
                pp_tun_ctrl_set_tunnel(ref, uuid, info)
            }
        }) else {
            throw PartoutError(.tunNotAvailable)
        }
        return TunWrapper(ctx, tun: tun)
    }

    public func configureSockets(with descriptors: [SocketDescriptor]) throws {
        try configureSockets(
            with: descriptors,
            reachability: currentReachability?.toCReachability
        )
    }

    private func configureSockets(
        with descriptors: [SocketDescriptor],
        reachability: pp_reachability?
    ) throws {
        let result = descriptors
            .withUnsafeBufferPointer { fds in
                guard let fdsBase = fds.baseAddress else {
                    return false
                }
                if let reachability {
                    return withUnsafePointer(to: reachability) { infoPtr in
                        pp_tun_ctrl_configure_sockets(ref, infoPtr, fdsBase, fds.count)
                    }
                } else {
                    return pp_tun_ctrl_configure_sockets(ref, nil, fdsBase, fds.count)
                }
            }
        guard result else {
            throw PartoutError(.socketConfiguration)
        }
    }

    public func reportSnapshot(_ snapshot: TunnelSnapshot) {
        pp_log(ctx, .core, .debug, "Report tunnel snapshot: \(snapshot)")
        do {
            let json = try JSONEncoder.shared().encodeJSON(snapshot)
            json.withCString {
                pp_tun_ctrl_report_snapshot(ref, $0)
            }
        } catch {
            pp_log(ctx, .core, .error, "Unable to encode snapshots: \(error)")
        }
    }

    public func environmentData(forKey key: String) -> Data? {
        pp_log(ctx, .core, .debug, "Get tunnel environment: \(key)")
        return environment.environmentData(forKey: key)
    }

    public func clearTunnelSettings(withKillSwitch: Bool) async {
        pp_log(ctx, .core, .debug, "Clear tunnel settings: withKillSwitch=\(withKillSwitch)")
        pp_tun_ctrl_clear_tunnel(ref, withKillSwitch)
    }

    public func setReasserting(_ reasserting: Bool) {
        // Do nothing
    }

    public func cancelTunnelConnection(with error: Error?) {
        guard let error else {
            pp_tun_ctrl_cancel_tunnel(ref, nil)
            return
        }
        error.partoutErrorCode.rawValue.withCString {
            pp_tun_ctrl_cancel_tunnel(ref, $0)
        }
    }
}

// MARK: - DNS

extension NativeTunnelController: DNSResolver {
    public var currentReachability: ReachabilityInfo? {
        reachabilityHolder.get()
    }

    public func resolve(
        _ hostname: String,
        flags: Set<DNSResolverFlag>,
        reachability: ReachabilityInfo?,
        timeout: Int
    ) async throws -> [DNSRecord] {
        try await dns.resolve(
            hostname,
            flags: flags,
            reachability: reachability ?? currentReachability,
            timeout: timeout
        )
    }
}

// MARK: - Streams

extension NativeTunnelController: ReachabilityObserver {
    public func startObserving() {
    }

    public func stopObserving() {
    }

    public var isReachable: Bool {
        onReachableStream.value
    }

    public var isReachableStream: AsyncStream<Bool> {
        onReachableStream.subscribe()
    }

    public var betterPathFactory: BetterPathStreamFactory {
        betterPathProxy
    }
}

private extension NativeTunnelController {
    func onReachability(_ reachability: UnsafePointer<pp_reachability>) {
        let isReachable = reachability.pointee.reachable
#if os(Android)
        pp_log(ctx, .core, .info, "Network reachability changed: reachable=\(isReachable), network_handle=\(reachability.pointee.network_handle)")
#else
        pp_log(ctx, .core, .info, "Network reachability changed: reachable=\(isReachable)")
#endif
        reachabilityHolder.set(reachability)
        onReachableStream.send(isReachable)
    }

    func onBetterPath() {
        betterPathProxy.onBetterPath()
    }
}

private final class ReachabilityHolder: @unchecked Sendable {
    private let lock = SemaphoreMutex()
    private var reachability: pp_reachability?

    nonisolated func get() -> ReachabilityInfo? {
        lock.with {
            guard let reachability else { return nil }
#if os(Android)
            return ReachabilityInfo(
                isReachable: reachability.reachable,
                networkHandle: reachability.network_handle
            )
#else
            return ReachabilityInfo(
                isReachable: reachability.reachable
            )
#endif
        }
    }

    nonisolated func set(_ new: UnsafePointer<pp_reachability>) {
        lock.with {
            reachability = new.pointee
        }
    }
}

private final class BetterPathProxy: BetterPathStreamFactory, @unchecked Sendable {
    private let lock = SemaphoreMutex()
    private var stream: PassthroughStream<Void>?

    nonisolated func newStream() -> PassthroughStream<Void> {
        let new = PassthroughStream<Void>()
        let oldStream = lock.with {
            let old = stream
            stream = new
            return old
        }
        oldStream?.finish()
        return new
    }

    func onBetterPath() {
        let current = lock.with {
            stream
        }
        current?.send()
    }
}

// MARK: - NetworkInterfaceFactory

extension NativeTunnelController: NetworkInterfaceFactory {
    private struct Observer: LinkObserver {
        let factory: NativeTunnelController
        let endpoint: ExtendedEndpoint

        func waitForActivity(timeout: Int) async throws -> LinkInterface {
            let reachability = factory.currentReachability
            let options = SocketWrapper.Options(
                endpoint: endpoint,
                timeout: timeout,
                bufSize: factory.bufSize,
                betterPathStream: factory.betterPathFactory.newStream(),
                reachability: reachability?.toCReachability,
                configure: { ctx, fd, reachability in
                    guard let ctx else { return true }
                    let ctrl = Unmanaged<NativeTunnelController>
                        .fromOpaque(ctx)
                        .takeUnretainedValue()
                    do {
                        try ctrl.configureSockets(
                            with: [fd],
                            reachability: reachability?.pointee
                        )
                        return true
                    } catch {
                        pp_log(ctrl.ctx, .core, .fault, "Unable to configure sockets: \(error)")
                        return false
                    }
                },
                configureCtx: UnsafeMutableRawPointer.fromSelf(factory)
            )
            return try await SocketWrapper(
                factory.ctx,
                options: options
            )
        }
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        Observer(factory: self, endpoint: endpoint)
    }
}

// MARK: - Helpers

private extension UnsafeMutableRawPointer {
    static func fromSelf(_ controller: NativeTunnelController) -> Self {
        Unmanaged.passUnretained(controller).toOpaque()
    }

    var toSelf: NativeTunnelController {
        Unmanaged.fromOpaque(self).takeUnretainedValue()
    }
}

private extension ReachabilityInfo {
    var toCReachability: pp_reachability {
#if os(Android)
        pp_reachability(
            reachable: isReachable,
            network_handle: networkHandle ?? 0
        )
#else
        pp_reachability(
            reachable: isReachable
        )
#endif
    }
}

private extension pp_reachability {
    var fromCReachability: ReachabilityInfo {
#if os(Android)
        ReachabilityInfo(
            isReachable: reachable,
            networkHandle: network_handle != 0 ? network_handle : nil
        )
#else
        ReachabilityInfo(isReachable: reachable)
#endif
    }
}

final class DummyTunnelInterface: TunInterface {
    func readPackets() async throws -> [Data] {
        []
    }

    func writePackets(_ packets: [Data]) async throws {
    }
}
