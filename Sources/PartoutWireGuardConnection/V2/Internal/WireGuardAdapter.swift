// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

internal import _PartoutCore_C
internal import _PartoutWireGuard_C

protocol WireGuardAdapterDelegate: AnyObject, Sendable {
    func adapterShouldReassert(_ adapter: WireGuardAdapter, reasserting: Bool)

    func adapterShouldSetNetworkSettings(_ adapter: WireGuardAdapter, settings: TunnelRemoteInfo) async throws -> IOInterface

    func adapterShouldConfigureSockets(_ adapter: WireGuardAdapter, descriptors: [UInt64]) throws

    func adapterShouldClearNetworkSettings(_ adapter: WireGuardAdapter, tunnel: IOInterface) async
}

/// Enum representing internal state of the `WireGuardAdapter`
private enum WireGuardAdapterState {
    /// The tunnel is stopped
    case stopped

    /// The tunnel is up and running
    case started(_ handle: Int32, _ settingsGenerator: TunnelRemoteInfoGenerator)

    /// The tunnel is temporarily shutdown due to device going offline
    case temporaryShutdown(_ settingsGenerator: TunnelRemoteInfoGenerator)
}

actor WireGuardAdapter {
    typealias LogHandler = @Sendable (WireGuardLogLevel, String) -> Void

    private static let temporaryShutdownRetryDelay = 2000

    private let ctx: PartoutLoggerContext

    /// Adapter delegate.
    private weak var delegate: WireGuardAdapterDelegate?

    /// The ID of the original ``WireGuardModule``.
    private let moduleId: UniqueID

    private let dns: DNSResolver?

    private let dnsTimeout: Int

    /// Backend implementation.
    private let backend: WireGuardBackend

    /// Network routes monitor.
    private unowned let reachability: ReachabilityObserver

    /// Log handler closure.
    private let logHandler: LogHandler

    /// Network reachability task.
    private var reachabilityTask: Task<Void, Never>?

    /// Backend restart retry task after transient failures while resuming from temporary shutdown.
    private var temporaryShutdownRetryTask: Task<Void, Never>?

    /// True while trying to restart the backend after a temporary shutdown.
    private var isRestartingBackend = false

    /// Virtual tunnel interface
    private var tunnel: IOInterface?

    /// Adapter state.
    private var state: WireGuardAdapterState = .stopped

    /// Tunnel device file descriptor.
    private var tunnelFileDescriptor: Int32? {
        didSet {
            logHandler(.verbose, "Tunnel file descriptor: \(tunnelFileDescriptor.debugDescription)")
        }
    }

    /// Returns a WireGuard version.
    var backendVersion: String {
        backend.version() ?? "unknown"
    }

    // MARK: - Initialization

    /// Designated initializer.
    init(
        _ ctx: PartoutLoggerContext,
        with delegate: WireGuardAdapterDelegate,
        moduleId: UniqueID,
        dns: DNSResolver?,
        dnsTimeout: Int,
        reachability: ReachabilityObserver,
        logHandler: @escaping LogHandler
    ) async {
        self.ctx = ctx
        self.delegate = delegate
        self.moduleId = moduleId
        self.dns = dns
        self.dnsTimeout = dnsTimeout
        backend = WireGuardBackend()
        self.reachability = reachability
        reachabilityTask = nil
        self.logHandler = logHandler

        setupReachabilityTask()
        setupLogHandler()
    }

    deinit {
        pp_log(ctx, .wireguard, .debug, "Deinit WireGuardAdapter")

        // Force remove logger to make sure that no further calls to the instance of this class
        // can happen after deallocation.
        backend.setLogger(context: nil, logger_fn: nil)

        reachabilityTask?.cancel()
        temporaryShutdownRetryTask?.cancel()

        // Shutdown the tunnel
        if case .started(let handle, _) = state {
            backend.turnOff(handle)
        }
    }

    // MARK: - Public methods

    /// Returns a runtime configuration from WireGuard.
    func getRuntimeConfiguration() async -> String? {
        guard case .started(let handle, _) = state else {
            return nil
        }
        return await Task.detached { [weak self] in
            guard let self else { return nil }
            guard let settings = backend.getConfig(handle) else { return nil }
            return settings
        }.value
    }

    /// Start the tunnel.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    func start(tunnelConfiguration: WireGuard.Configuration) async throws {
        pp_log(ctx, .wireguard, .info, "Start adapter")
        guard case .stopped = state else {
            throw WireGuardAdapterError.invalidState
        }
        do {
            let settingsGenerator = makeSettingsGenerator(with: tunnelConfiguration)
            try await settingsGenerator.cacheResolvedPeerEndpoints(logHandler: logHandler)
            try await setNetworkSettings(settingsGenerator.generateRemoteInfo(
                moduleId: moduleId
            ))
            let wgConfig = try await settingsGenerator.uapiConfiguration(logHandler: logHandler)
            let handle = try startWireGuardBackend(wgConfig: wgConfig)
            state = .started(handle, settingsGenerator)
        } catch {
            reachabilityTask?.cancel()
            reachabilityTask = nil
            cancelTemporaryShutdownRetry()
            if case .started(let handle, _) = state {
                backend.turnOff(handle)
            }
            state = .stopped
            if let tunnel {
                await delegate?.adapterShouldClearNetworkSettings(self, tunnel: tunnel)
                self.tunnel = nil
            }
            pp_log(ctx, .wireguard, .fault, "Unable to start: \(error)")
            throw error
        }
    }

    /// Stop the tunnel.
    func stop() async throws {
        pp_log(ctx, .wireguard, .info, "Stop adapter")
        switch state {
        case .started(let handle, _):
            backend.turnOff(handle)
        case .temporaryShutdown:
            break
        case .stopped:
            throw WireGuardAdapterError.invalidState
        }
        state = .stopped
        reachabilityTask?.cancel()
        reachabilityTask = nil
        cancelTemporaryShutdownRetry()
        if let tunnel {
            await delegate?.adapterShouldClearNetworkSettings(self, tunnel: tunnel)
            self.tunnel = nil
        }
    }

    // MARK: - Private methods

    private func setupReachabilityTask() {
        let stream = reachability.isReachableStream
        reachabilityTask = Task { [weak self] in
            for await isReachable in stream {
                guard !Task.isCancelled else { return }
                do {
                    try await self?.didUpdateReachable(isReachable: isReachable)
                } catch {
                    self?.logHandler(.error, "Unable to update reachability: \(error)")
                }
            }
        }
    }

    /// Setup WireGuard log handler.
    private func setupLogHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        backend.setLogger(context: context) { context, logLevel, message in
            guard let context, let message else { return }

            let unretainedSelf = Unmanaged<WireGuardAdapter>.fromOpaque(context)
                .takeUnretainedValue()

            let swiftString = String(cString: message).trimmingCharacters(in: .newlines)
            let tunnelLogLevel = WireGuardLogLevel(rawValue: logLevel) ?? .verbose

            unretainedSelf.logHandler(tunnelLogLevel, swiftString)
        }
    }

    /// Set network tunnel configuration.
    /// This method ensures that the call to `setTunnelNetworkSettings` does not time out, as in
    /// certain scenarios the completion handler given to it may not be invoked by the system.
    ///
    /// - Parameters:
    ///   - networkSettings: an instance of type `TunnelRemoteInfo`.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: `PacketTunnelSettingsGenerator`.
    private func setNetworkSettings(_ networkSettings: TunnelRemoteInfo) async throws {
        guard let delegate else { return }
        tunnel = try await delegate.adapterShouldSetNetworkSettings(self, settings: networkSettings)
#if !os(Windows)
        guard let tunFd = tunnel?.fileDescriptor.map(Int32.init) ?? fallbackFileDescriptor else {
            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
        }
        tunnelFileDescriptor = tunFd
#endif
    }

    /// Start WireGuard backend.
    /// - Parameter wgConfig: WireGuard configuration
    /// - Throws: an error of type `WireGuardAdapterError`
    /// - Returns: tunnel handle
    private func startWireGuardBackend(wgConfig: String) throws -> Int32 {
#if os(Windows)
        guard let interfaceName else {
            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
        }
        let handle = backend.turnOn(settings: wgConfig, ifname: interfaceName)
#else
        guard let tunnelFileDescriptor else {
            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
        }
        let handle = backend.turnOn(settings: wgConfig, tun_fd: tunnelFileDescriptor)
#endif
        if handle < 0 {
            throw WireGuardAdapterError.startWireGuardBackend(handle)
        }
#if os(iOS)
        backend.disableSomeRoamingForBrokenMobileSemantics(handle)
#endif
        try configureSockets(for: handle)
        return handle
    }

    @discardableResult
    private func configureSockets(for handle: Int32) throws -> [UInt64] {
        let descriptors = backend.socketDescriptors(handle)
            .filter { $0 >= 0 }
            .map { UInt64($0) }
        pp_log(ctx, .wireguard, .info, "Socket descriptors: \(descriptors)")
        guard !descriptors.isEmpty else { return [] }
        try delegate?.adapterShouldConfigureSockets(self, descriptors: descriptors)
        return descriptors
    }

    /// Resolves the hostnames in the given tunnel configuration and return settings generator.
    /// - Parameter tunnelConfiguration: an instance of type `WireGuard.Configuration`.
    /// - Returns: an instance of type `TunnelRemoteInfoGenerator`.
    private func makeSettingsGenerator(with tunnelConfiguration: WireGuard.Configuration) -> TunnelRemoteInfoGenerator {
        TunnelRemoteInfoGenerator(
            ctx,
            tunnelConfiguration: tunnelConfiguration,
            dns: dns,
            dnsTimeout: dnsTimeout
        )
    }

    private func didUpdateReachable(isReachable: Bool) async throws {
//        logHandler(.verbose, "Network change detected with \(path.status) route and interface order \(path.availableInterfaces)")
        logHandler(.verbose, "Network change detected, reachable: \(isReachable)")

#if os(macOS)
        if case .started(let handle, _) = self.state {
            await backend.bumpSocketsAndWait(handle)
            try configureSockets(for: handle)
        }
#else
        switch state {
        case .started(let handle, let settingsGenerator):
            cancelTemporaryShutdownRetry()
            if isReachable {
                let wgConfig = await settingsGenerator.endpointUapiConfiguration(logHandler: logHandler)

                backend.setConfig(handle, settings: wgConfig)
                backend.disableSomeRoamingForBrokenMobileSemantics(handle)
                await backend.bumpSocketsAndWait(handle)
                try configureSockets(for: handle)
            } else {
                logHandler(.verbose, "Connectivity offline, pausing backend.")

                state = .temporaryShutdown(settingsGenerator)
                backend.turnOff(handle)
            }

        case .temporaryShutdown(let settingsGenerator):
            guard isReachable else {
                cancelTemporaryShutdownRetry()
                return
            }
            await restartBackend(settingsGenerator)

        case .stopped:
            // no-op
            break
        }
#endif
    }

    private func restartBackend(_ settingsGenerator: TunnelRemoteInfoGenerator) async {
        guard !isRestartingBackend else {
            return
        }
        isRestartingBackend = true
        defer {
            isRestartingBackend = false
        }
        cancelTemporaryShutdownRetry()
        logHandler(.verbose, "Connectivity online, resuming backend.")
        do {
            await settingsGenerator.resetResolvedEndpoints()
            try await settingsGenerator.cacheResolvedPeerEndpoints(logHandler: logHandler)
            guard isTemporarilyShutdown(with: settingsGenerator) else {
                return
            }
            try await setNetworkSettings(settingsGenerator.generateRemoteInfo(
                moduleId: moduleId
            ))
            guard isTemporarilyShutdown(with: settingsGenerator) else {
                if let tunnel {
                    await delegate?.adapterShouldClearNetworkSettings(self, tunnel: tunnel)
                    self.tunnel = nil
                }
                return
            }
            let wgConfig = try await settingsGenerator.uapiConfiguration(logHandler: logHandler)
            guard isTemporarilyShutdown(with: settingsGenerator) else {
                if let tunnel {
                    await delegate?.adapterShouldClearNetworkSettings(self, tunnel: tunnel)
                    self.tunnel = nil
                }
                return
            }
            let handle = try startWireGuardBackend(wgConfig: wgConfig)
            state = .started(handle, settingsGenerator)
        } catch {
            logHandler(.error, "Failed to restart backend: \(error.localizedDescription)")
            scheduleTemporaryShutdownRetry(for: settingsGenerator)
        }
    }

    private func scheduleTemporaryShutdownRetry(for settingsGenerator: TunnelRemoteInfoGenerator) {
        guard isTemporarilyShutdown(with: settingsGenerator), reachability.isReachable else {
            return
        }
        guard temporaryShutdownRetryTask == nil else {
            return
        }
        logHandler(.verbose, "Retry backend restart in \(Self.temporaryShutdownRetryDelay) milliseconds")
        temporaryShutdownRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(milliseconds: Self.temporaryShutdownRetryDelay)
            } catch {
                return
            }
            await self?.retryTemporaryShutdown(settingsGenerator)
        }
    }

    private func retryTemporaryShutdown(_ settingsGenerator: TunnelRemoteInfoGenerator) async {
        temporaryShutdownRetryTask = nil
        guard reachability.isReachable, isTemporarilyShutdown(with: settingsGenerator) else {
            return
        }
        await restartBackend(settingsGenerator)
    }

    private func cancelTemporaryShutdownRetry() {
        temporaryShutdownRetryTask?.cancel()
        temporaryShutdownRetryTask = nil
    }

    private func isTemporarilyShutdown(with settingsGenerator: TunnelRemoteInfoGenerator) -> Bool {
        guard case .temporaryShutdown(let currentSettingsGenerator) = state else {
            return false
        }
        return currentSettingsGenerator === settingsGenerator
    }

    private nonisolated var fallbackFileDescriptor: Int32? {
#if canImport(Darwin)
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                return fd
            }
        }
        return nil
#else
        return nil
#endif
    }
}

// MARK: - Low-level

extension WireGuardAdapter {
    /// Returns the tunnel device interface name, or nil if unsupported or on error.
    var interfaceName: String? {
#if os(Windows)
        moduleId.uuidString
#elseif canImport(Darwin)
        guard let tunnelFileDescriptor else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(IFNAMSIZ))
        return buffer.withUnsafeMutableBufferPointer { mutableBufferPointer in
            guard let baseAddress = mutableBufferPointer.baseAddress else { return nil }

            var ifnameSize = socklen_t(IFNAMSIZ)
            let result = getsockopt(
                tunnelFileDescriptor,
                2 /* SYSPROTO_CONTROL */,
                2 /* UTUN_OPT_IFNAME */,
                baseAddress,
                &ifnameSize)

            guard result == 0 else { return nil }
            return String(cString: baseAddress)
        }
#else
        nil
#endif
    }
}
