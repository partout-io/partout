// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

internal import _PartoutWireGuard_C

protocol WireGuardAdapterDelegate: AnyObject {
    func adapterShouldReassert(_ adapter: WireGuardAdapter, reasserting: Bool)

    func adapterShouldSetNetworkSettings(_ adapter: WireGuardAdapter, settings: TunnelRemoteInfo) async throws -> IOInterface

    func adapterShouldConfigureSockets(_ adapter: WireGuardAdapter, descriptors: [UInt64])
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

class WireGuardAdapter: @unchecked Sendable {
    typealias LogHandler = @Sendable (WireGuardLogLevel, String) -> Void

    private let ctx: PartoutLoggerContext

    /// Reachability monitor.
    private var reachabilityTask: Task<Void, Never>?

    /// Adapter delegate.
    private weak var delegate: WireGuardAdapterDelegate?

    /// The ID of the original ``WireGuardModule``.
    private let moduleId: UniqueID

    private let dnsTimeout: Int

    /// Reachability observer.
    private unowned let reachability: ReachabilityObserver

    /// Log handler closure.
    private let logHandler: LogHandler

    /// Backend implementation.
    private let backend: WireGuardBackend

    /// Private queue used to synchronize access to `WireGuardAdapter` members.
    private let workQueue = DispatchQueue(label: "WireGuardAdapterWorkQueue")

    /// Virtual tunnel interface.
    private var tunnel: IOInterface?

    /// Adapter state.
    private var state: WireGuardAdapterState = .stopped

    private var socketDescriptors: [Int32] {
        guard case .started(let handle, _) = state else { return [] }
        return backend.socketDescriptors(handle)
    }

    /// Tunnel device file descriptor.
    private var tunnelFileDescriptor: Int32? {
        tunnel?.fileDescriptor.map(Int32.init)
    }

    /// Returns a WireGuard version.
    var backendVersion: String {
        backend.version() ?? "unknown"
    }

    /// Returns the tunnel device interface name, or nil on error.
    /// - Returns: String.
    var interfaceName: String? {
#if os(Windows)
        moduleId.uuidString
#else
        nil
#endif
    }

    // MARK: - Initialization

    /// Designated initializer.
    /// - Parameter delegate: an instance of `WireGuardAdapterDelegate`. Internally stored
    ///   as a weak reference.
    /// - Parameter backend: a backend implementation.
    /// - Parameter logHandler: a log handler closure.
    init(
        _ ctx: PartoutLoggerContext,
        with delegate: WireGuardAdapterDelegate,
        moduleId: UniqueID,
        dnsTimeout: Int,
        reachability: ReachabilityObserver,
        backend: WireGuardBackend = WireGuardBackend(),
        logHandler: @escaping LogHandler
    ) {
        self.ctx = ctx
        self.delegate = delegate
        self.moduleId = moduleId
        self.dnsTimeout = dnsTimeout
        self.reachability = reachability
        self.backend = backend
        self.logHandler = logHandler

        setupLogHandler()
    }

    deinit {
        pp_log(ctx, .wireguard, .debug, "Deinit WireGuardAdapter")

        // Force remove logger to make sure that no further calls to the instance of this class
        // can happen after deallocation.
        backend.setLogger(context: nil, logger_fn: nil)

        // Cancel reachability monitor
        reachabilityTask?.cancel()

        // Shutdown the tunnel
        if case .started(let handle, _) = self.state {
            backend.turnOff(handle)
        }
    }

    // MARK: - Public methods

    /// Returns a runtime configuration from WireGuard.
    /// - Parameter completionHandler: completion handler.
    func getRuntimeConfiguration(completionHandler: @escaping @Sendable (String?) -> Void) {
        workQueue.async {
            guard case .started(let handle, _) = self.state else {
                completionHandler(nil)
                return
            }

            if let settings = self.backend.getConfig(handle) {
                completionHandler(settings)
            } else {
                completionHandler(nil)
            }
        }
    }

    /// Start the tunnel tunnel.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    func start(tunnelConfiguration: WireGuard.Configuration, completionHandler: @escaping @Sendable (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            guard case .stopped = self.state else {
                completionHandler(.invalidState)
                return
            }

            self.setupReachabilityTask()

            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateRemoteInfo(
                    moduleId: self.moduleId,
                    descriptors: self.socketDescriptors
                ))

                let wgConfig = try settingsGenerator.uapiConfiguration(logHandler: self.logHandler)

                self.state = .started(
                    try self.startWireGuardBackend(wgConfig: wgConfig),
                    settingsGenerator
                )
                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                self.reachabilityTask?.cancel()
                self.reachabilityTask = nil
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Stop the tunnel.
    /// - Parameter completionHandler: completion handler.
    func stop(completionHandler: @escaping @Sendable (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            switch self.state {
            case .started(let handle, _):
                self.backend.turnOff(handle)

            case .temporaryShutdown:
                break

            case .stopped:
                completionHandler(.invalidState)
                return
            }

            self.reachabilityTask?.cancel()
            self.reachabilityTask = nil

            self.state = .stopped

            completionHandler(nil)
        }
    }

    // MARK: - Private methods

    private func setupReachabilityTask() {
        let stream = reachability.isReachableStream
        reachabilityTask = Task { [weak self] in
            for await isReachable in stream {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                workQueue.async {
                    self.didReceiveReachabilityUpdate(isReachable: isReachable)
                }
            }
        }
    }

    /// Setup WireGuard log handler.
    private func setupLogHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        backend.setLogger(context: context) { context, logLevel, message in
            guard let context = context, let message = message else { return }

            let unretainedSelf = Unmanaged<WireGuardAdapter>.fromOpaque(context)
                .takeUnretainedValue()

            let swiftString = String(cString: message).trimmingCharacters(in: .newlines)
            let tunnelLogLevel = WireGuardLogLevel(rawValue: logLevel) ?? .verbose

            unretainedSelf.logHandler(tunnelLogLevel, swiftString)
        }
    }

    /// Set network tunnel configuration.
    /// This method ensures that the call to Partout tunnel settings does not time out, as in
    /// certain scenarios the completion may not be invoked by the system.
    ///
    /// - Parameters:
    ///   - networkSettings: an instance of type `TunnelRemoteInfo`.
    /// - Throws: an error of type `WireGuardAdapterError`.
    private func setNetworkSettings(_ networkSettings: TunnelRemoteInfo) throws {
        nonisolated(unsafe) var systemResult: Result<IOInterface, Error>?
        let condition = NSCondition()

        // Activate the condition
        condition.lock()
        defer { condition.unlock() }

        if let delegate {
            Task { [weak self] in
                guard let self else { return }
                let result: Result<IOInterface, Error>
                do {
                    result = .success(try await delegate.adapterShouldSetNetworkSettings(self, settings: networkSettings))
                } catch {
                    result = .failure(error)
                }
                Self.signal(condition) {
                    systemResult = result
                }
            }
        }

        // Packet tunnel's `setTunnelNetworkSettings` times out in certain
        // scenarios & never calls the given callback.
        let setTunnelNetworkSettingsTimeout: TimeInterval = 5 // seconds

        if condition.wait(until: Date().addingTimeInterval(setTunnelNetworkSettingsTimeout)) {
            if let systemResult {
                switch systemResult {
                case .success(let tunnel):
                    self.tunnel = tunnel
                case .failure(let systemError):
                    throw WireGuardAdapterError.setNetworkSettings(systemError)
                }
            }
        } else {
            self.logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
        }
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
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
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
        let socketFds = {
            var rawFds = backend.socketDescriptors(handle)
            if rawFds.isEmpty {
                rawFds = self.tunnelFileDescriptor.map { [$0] } ?? []
            }
            return rawFds
        }()
        pp_log(ctx, .wireguard, .info, "Socket descriptors: \(socketFds)")
        delegate?.adapterShouldConfigureSockets(self, descriptors: socketFds.map(UInt64.init))
        return handle
    }

    /// Resolves the hostnames in the given tunnel configuration and return settings generator.
    /// - Parameter tunnelConfiguration: an instance of type `WireGuard.Configuration`.
    /// - Returns: an instance of type `TunnelRemoteInfoGenerator`.
    private func makeSettingsGenerator(with tunnelConfiguration: WireGuard.Configuration) throws -> TunnelRemoteInfoGenerator {
        let resolvedEndpoints = try awaitResult {
            try await tunnelConfiguration.resolvePeers(
                timeout: self.dnsTimeout,
                logHandler: self.logHandler
            )
        }
        return TunnelRemoteInfoGenerator(
            ctx,
            tunnelConfiguration: tunnelConfiguration,
            resolvedEndpoints: resolvedEndpoints
        )
    }

    /// Helper method used by the reachability monitor.
    /// - Parameter isReachable: whether the network is currently reachable.
    private func didReceiveReachabilityUpdate(isReachable: Bool) {
        self.logHandler(.verbose, "Network change detected, reachable: \(isReachable)")

#if os(macOS)
        if case .started(let handle, _) = self.state {
            backend.bumpSockets(handle)
        }
#elseif os(iOS) || os(tvOS)
        handleMobileReachabilityUpdate(isReachable: isReachable)
#else
        handleMobileReachabilityUpdate(isReachable: isReachable)
#endif
    }

    private func handleMobileReachabilityUpdate(isReachable: Bool) {
        switch self.state {
        case .started(let handle, let settingsGenerator):
            if isReachable {
                let wgConfig = settingsGenerator.endpointUapiConfiguration(logHandler: self.logHandler)

                backend.setConfig(handle, settings: wgConfig)
                backend.disableSomeRoamingForBrokenMobileSemantics(handle)
                backend.bumpSockets(handle)
            } else {
                self.logHandler(.verbose, "Connectivity offline, pausing backend.")

                self.state = .temporaryShutdown(settingsGenerator)
                backend.turnOff(handle)
            }

        case .temporaryShutdown(let settingsGenerator):
            guard isReachable else { return }

            self.logHandler(.verbose, "Connectivity online, resuming backend.")

            do {
                try self.setNetworkSettings(settingsGenerator.generateRemoteInfo(
                    moduleId: moduleId,
                    descriptors: socketDescriptors
                ))

                let wgConfig = try settingsGenerator.uapiConfiguration(logHandler: self.logHandler)

                self.state = .started(
                    try self.startWireGuardBackend(wgConfig: wgConfig),
                    settingsGenerator
                )
            } catch {
                self.logHandler(.error, "Failed to restart backend: \(error.localizedDescription)")
            }

        case .stopped:
            // no-op
            break
        }
    }

    private func awaitResult<T: Sendable>(_ block: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        let condition = NSCondition()

        condition.lock()
        defer { condition.unlock() }

        Task {
            let taskResult: Result<T, Error>
            do {
                taskResult = .success(try await block())
            } catch {
                taskResult = .failure(error)
            }
            Self.signal(condition) {
                result = taskResult
            }
        }

        while result == nil {
            condition.wait()
        }
        return try result!.get()
    }

    private static func signal(_ condition: NSCondition, update: () -> Void) {
        condition.lock()
        update()
        condition.signal()
        condition.unlock()
    }
}
