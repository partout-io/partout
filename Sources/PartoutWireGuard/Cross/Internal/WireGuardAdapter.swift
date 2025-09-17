// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import _PartoutWireGuard_C
import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

let AF_SYSTEM = 32

protocol WireGuardAdapterDelegate: AnyObject, Sendable {
    func adapterShouldReassert(_ adapter: WireGuardAdapter, reasserting: Bool)

    func adapterShouldSetNetworkSettings(_ adapter: WireGuardAdapter, settings: TunnelRemoteInfo) async throws -> IOInterface

    func adapterShouldConfigureSockets(_ adapter: WireGuardAdapter, descriptors: [UInt64])

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

    private let ctx: PartoutLoggerContext

    /// Adapter delegate.
    private weak var delegate: WireGuardAdapterDelegate?

    /// The ID of the original ``WireGuardModule``.
    private let moduleId: UniqueID

    private let dnsTimeout: Int

    /// Backend implementation.
    private let backend: WireGuardBackend

    /// Network routes monitor.
    private unowned let reachability: ReachabilityObserver

    /// Log handler closure.
    private let logHandler: LogHandler

    /// Network reachability task.
    private var reachabilityTask: Task<Void, Never>?

    /// Virtual tunnel interface
    private var tunnel: IOInterface?

    /// Adapter state.
    private var state: WireGuardAdapterState = .stopped

    private var socketDescriptors: [Int32] {
        guard case .started(let handle, _) = state else { return [] }
        return backend.socketDescriptors(handle)
    }

    /// Tunnel device file descriptor.
    private var tunnelFileDescriptor: Int32? {
        didSet {
            logHandler(.verbose, "Tunnel file descriptor: \(tunnelFileDescriptor.debugDescription)")
            logHandler(.verbose, "Socket file descriptors: \(socketDescriptors)")
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
        dnsTimeout: Int,
        reachability: ReachabilityObserver,
        logHandler: @escaping LogHandler
    ) async {
        self.ctx = ctx
        self.delegate = delegate
        self.moduleId = moduleId
        self.dnsTimeout = dnsTimeout
        backend = WireGuardBackend()
        self.reachability = reachability
        reachabilityTask = nil
        self.logHandler = logHandler

        setupReachabilityTask()
        setupLogHandler()
    }

    deinit {
        pp_log(ctx, .wireguard, .info, "Deinit WireGuardAdapter")

        // Force remove logger to make sure that no further calls to the instance of this class
        // can happen after deallocation.
        backend.setLogger(context: nil, logger_fn: nil)

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
            let wgConfig = try await settingsGenerator.uapiConfiguration(logHandler: logHandler)
            try await setNetworkSettings(settingsGenerator.generateRemoteInfo(
                moduleId: moduleId,
                descriptors: socketDescriptors
            ))
            let handle = try startWireGuardBackend(wgConfig: wgConfig)
            state = .started(handle, settingsGenerator)
        } catch let error as WireGuardAdapterError {
            throw error
        } catch {
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
        if let tunnel {
            await delegate?.adapterShouldClearNetworkSettings(self, tunnel: tunnel)
            self.tunnel = nil
        }
    }

    /// Update runtime configuration.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    func update(tunnelConfiguration: WireGuard.Configuration) async throws {
        if case .stopped = state {
            throw WireGuardAdapterError.invalidState
        }

        // Tell the system that the tunnel is going to reconnect using new WireGuard
        // configuration.
        // This will broadcast the `NEVPNStatusDidChange` notification to the GUI process.
        delegate?.adapterShouldReassert(self, reasserting: true)
        defer {
            delegate?.adapterShouldReassert(self, reasserting: false)
        }

        do {
            let settingsGenerator = makeSettingsGenerator(with: tunnelConfiguration)
            let wgConfig = try await settingsGenerator.uapiConfiguration(logHandler: logHandler)
            try await setNetworkSettings(settingsGenerator.generateRemoteInfo(
                moduleId: moduleId,
                descriptors: socketDescriptors
            ))

            switch state {
            case .started(let handle, _):
                backend.setConfig(handle, settings: wgConfig)
#if os(iOS)
                backend.disableSomeRoamingForBrokenMobileSemantics(handle)
#endif
                state = .started(handle, settingsGenerator)
            case .temporaryShutdown:
                state = .temporaryShutdown(settingsGenerator)
            case .stopped:
                fatalError()
            }
        } catch let error as WireGuardAdapterError {
            throw error
        } catch {
            fatalError()
        }
    }

    // MARK: - Private methods

    private func setupReachabilityTask() {
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            for await isReachable in reachability.isReachableStream {
                guard !Task.isCancelled else { return }
                do {
                    try await didUpdateReachable(isReachable: isReachable)
                } catch {
                    pp_log(ctx, .wireguard, .error, "Unable to update reachability: \(error)")
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
        let socketFds = backend.socketDescriptors(handle)
        pp_log(ctx, .wireguard, .info, "Socket descriptors: \(socketFds)")
        delegate?.adapterShouldConfigureSockets(self, descriptors: socketFds.map(UInt64.init))
        return handle
    }

    /// Resolves the hostnames in the given tunnel configuration and return settings generator.
    /// - Parameter tunnelConfiguration: an instance of type `WireGuard.Configuration`.
    /// - Returns: an instance of type `TunnelRemoteInfoGenerator`.
    private func makeSettingsGenerator(with tunnelConfiguration: WireGuard.Configuration) -> TunnelRemoteInfoGenerator {
        TunnelRemoteInfoGenerator(tunnelConfiguration: tunnelConfiguration, dnsTimeout: dnsTimeout)
    }

    private func didUpdateReachable(isReachable: Bool) async throws {
//        logHandler(.verbose, "Network change detected with \(path.status) route and interface order \(path.availableInterfaces)")
        logHandler(.verbose, "Network change detected, reachable: \(isReachable)")

        switch state {
        case .started(let handle, let settingsGenerator):
            if isReachable {
                let wgConfig = try await settingsGenerator.uapiConfiguration(logHandler: logHandler)

                backend.setConfig(handle, settings: wgConfig)
                backend.disableSomeRoamingForBrokenMobileSemantics(handle)
                backend.bumpSockets(handle)
            } else {
                logHandler(.verbose, "Connectivity offline, pausing backend.")

                state = .temporaryShutdown(settingsGenerator)
                backend.turnOff(handle)
            }

        case .temporaryShutdown(let settingsGenerator):
            guard isReachable else { return }
            logHandler(.verbose, "Connectivity online, resuming backend.")
            do {
                let wgConfig = try await settingsGenerator.uapiConfiguration(logHandler: logHandler)
                try await setNetworkSettings(settingsGenerator.generateRemoteInfo(
                    moduleId: moduleId,
                    descriptors: socketDescriptors
                ))
                let handle = try startWireGuardBackend(wgConfig: wgConfig)
                state = .started(handle, settingsGenerator)
            } catch {
                logHandler(.error, "Failed to restart backend: \(error.localizedDescription)")
            }

        case .stopped:
            // no-op
            break
        }
    }

    private nonisolated var fallbackFileDescriptor: Int32? {
#if os(macOS) || os(iOS) || os(tvOS)
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

#if os(Windows)

extension WireGuardAdapter {
    var interfaceName: String? {
        moduleId.uuidString
    }
}

#else

extension WireGuardAdapter {

    /// Returns the tunnel device interface name, or nil on error.
    /// - Returns: String.
    var interfaceName: String? {
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
    }
}

#endif
