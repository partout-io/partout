// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//  SPDX-License-Identifier: MIT
//  Copyright © 2018-2024 WireGuard LLC. All Rights Reserved.

#if !USE_CMAKE
@_exported import PartoutWireGuard
#endif

/// Establishes a WireGuard connection.
public actor WireGuardConnectionV2: Connection {
    private let ctx: PartoutLoggerContext

    private let statusSubject: CurrentValueStream<ConnectionStatus>

    private let moduleId: UniqueID

    private let controller: TunnelController

    private let reachability: ReachabilityObserver

    private let environment: TunnelEnvironment

    private let dnsTimeout: Int

    private let tunnelConfiguration: WireGuard.Configuration

    private let dataCountTimerInterval: TimeInterval

    private var dataCountTimer: Task<Void, Error>?

    private var adapter: WireGuardAdapterV2?

    public init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: WireGuardModule
    ) throws {
        self.ctx = ctx
        statusSubject = CurrentValueStream(.disconnected)
        moduleId = module.id
        controller = parameters.controller
        reachability = parameters.reachability
        environment = parameters.environment
        dnsTimeout = parameters.options.dnsTimeout

        guard let configuration = module.configuration else {
            throw PartoutError(.incompleteModule)
        }
        pp_log(ctx, .wireguard, .notice, "WireGuard: Using cross-platform connection V2")

        tunnelConfiguration = try configuration.withModulesV2(from: parameters.profile)
        dataCountTimerInterval = TimeInterval(parameters.options.minDataCountInterval) / 1000.0
    }

    deinit {
        pp_log(ctx, .wireguard, .info, "Deinit WireGuardConnectionV2")
    }

    public nonisolated var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject.subscribeThrowing()
    }

    public func start() async throws -> Bool {
        assert(adapter == nil)
        adapter = await WireGuardAdapterV2(
            ctx,
            with: self,
            moduleId: moduleId,
            dnsTimeout: dnsTimeout,
            reachability: reachability,
            logHandler: { [weak self] logLevel, message in
                pp_log(self?.ctx ?? .global, .wireguard, logLevel.debugLevelV2, message)
            }
        )
        guard let adapter else { return false }
        pp_log(ctx, .wireguard, .info, "Start tunnel")
        statusSubject.send(.connecting)

        dataCountTimer?.cancel()
        dataCountTimer = Task { [weak self] in
            while true {
                guard let self else {
                    return
                }
                guard !Task.isCancelled else {
                    pp_log(ctx, .wireguard, .debug, "Cancelled WireGuardConnectionV2.dataCountTimer")
                    return
                }
                await onDataCountTimer()
                try await Task.sleep(interval: dataCountTimerInterval)
            }
        }

        do {
            try await adapter.start(tunnelConfiguration: tunnelConfiguration)
            let interfaceName = await adapter.interfaceName ?? "unknown"
            pp_log(ctx, .wireguard, .info, "Tunnel interface is \(interfaceName)")
            return true
        } catch {
            if let adapterError = error as? WireGuardAdapterError {
                switch adapterError {
                case .cannotLocateTunnelFileDescriptor:
                    pp_log(ctx, .wireguard, .error, "Starting tunnel failed: could not determine file descriptor")
                    throw WireGuardConnectionError.couldNotDetermineFileDescriptor
                case .setNetworkSettings(let error):
                    pp_log(ctx, .wireguard, .error, "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                    throw WireGuardConnectionError.couldNotSetNetworkSettings
                case .startWireGuardBackend(let errorCode):
                    pp_log(ctx, .wireguard, .error, "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                    throw WireGuardConnectionError.couldNotStartBackend
                case .invalidState:
                    // Must never happen
                    fatalError()
                }
            }
            statusSubject.send(.disconnected)
            throw error
        }
    }

    public func stop(timeout: Int) async {
        guard let adapter else { return }
        pp_log(ctx, .wireguard, .info, "Stop tunnel")
        statusSubject.send(.disconnecting)
        // XXX: Ignore timeout, the stop call is typically snappy
        do {
            try await adapter.stop()
        } catch {
            pp_log(ctx, .wireguard, .error, "Unable to stop WireGuard adapter: \(error.localizedDescription)")
        }
        statusSubject.send(.disconnected)
        dataCountTimer?.cancel()
        dataCountTimer = nil
        self.adapter = nil
    }
}

private extension WireGuardLogLevel {
    var debugLevelV2: DebugLog.Level {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}

// MARK: - WireGuardAdapterDelegate

extension WireGuardConnectionV2: WireGuardAdapterV2Delegate {
    nonisolated func adapterShouldReassert(_ adapter: WireGuardAdapterV2, reasserting: Bool) {
        if reasserting {
            statusSubject.send(.connecting)
        }
    }

    func adapterShouldSetNetworkSettings(_ adapter: WireGuardAdapterV2, settings: TunnelRemoteInfo) async throws -> IOInterface {
        do {
            let tunnel = try await controller.setTunnelSettings(with: settings)
            pp_log(ctx, .wireguard, .info, "Tunnel interface is now UP")
            statusSubject.send(.connected)
            return tunnel
        } catch {
            pp_log(ctx, .wireguard, .error, "Unable to configure tunnel settings: \(error)")
            statusSubject.send(.disconnected)
            throw error
        }
    }

    nonisolated func adapterShouldConfigureSockets(_ adapter: WireGuardAdapterV2, descriptors: [UInt64]) {
        controller.configureSockets(with: descriptors)
    }

    func adapterShouldClearNetworkSettings(_ adapter: WireGuardAdapterV2, tunnel: IOInterface) async {
        await controller.clearTunnelSettings(tunnel)
    }
}

// MARK: - Data count

private extension WireGuardConnectionV2 {
    func onDataCountTimer() async {
        guard let adapter else { return }
        guard statusSubject.value == .connected else { return }
        guard let configurationString = await adapter.getRuntimeConfiguration(),
              let dataCount = DataCount.fromWireGuardStringV2(configurationString) else {
            return
        }
        environment.setEnvironmentValue(dataCount, forKey: TunnelEnvironmentKeys.dataCount)
    }
}

private extension DataCount {
    static func fromWireGuardStringV2(_ string: String) -> DataCount? {
        var bytesReceived: UInt?
        var bytesSent: UInt?
        string.enumerateLines { line, stop in
            if bytesReceived == nil, let value = line.getPrefixV2("rx_bytes=") {
                bytesReceived = value
            } else if bytesSent == nil, let value = line.getPrefixV2("tx_bytes=") {
                bytesSent = value
            }
            if bytesReceived != nil, bytesSent != nil {
                stop = true
            }
        }
        guard let bytesReceived, let bytesSent else { return nil }
        return DataCount(bytesReceived, bytesSent)
    }
}

private extension String {
    func getPrefixV2(_ prefixKey: String) -> UInt? {
        guard hasPrefix(prefixKey) else {
            return nil
        }
        return UInt(dropFirst(prefixKey.count))
    }
}

// MARK: - Helpers

private extension WireGuard.Configuration {
    func withModulesV2(from profile: Profile) throws -> Self {
        var newBuilder = builder()

        // add IPModule.*.includedRoutes to AllowedIPs
        profile.activeModules
            .compactMap {
                $0 as? IPModule
            }
            .forEach { ipModule in
                newBuilder.peers = newBuilder.peers
                    .map { oldPeer in
                        var peer = oldPeer
                        ipModule.ipv4?.includedRoutes.forEach { route in
                            peer.allowedIPs.append(route.destination?.rawValue ?? "0.0.0.0/0")
                        }
                        ipModule.ipv6?.includedRoutes.forEach { route in
                            peer.allowedIPs.append(route.destination?.rawValue ?? "::/0")
                        }
                        return peer
                    }
            }

        // if routesThroughVPN, add DNSModule.servers to AllowedIPs
        profile.activeModules
            .compactMap {
                $0 as? DNSModule
            }
            .filter {
                $0.routesThroughVPN == true
            }
            .forEach { dnsModule in
                newBuilder.peers = newBuilder.peers
                    .map { oldPeer in
                        var peer = oldPeer
                        dnsModule.servers.forEach {
                            switch $0 {
                            case .ip(let addr, let family):
                                switch family {
                                case .v4:
                                    peer.allowedIPs.append("\(addr)/32")
                                case .v6:
                                    peer.allowedIPs.append("\(addr)/128")
                                }
                            case .hostname:
                                break
                            }
                        }
                        return peer
                    }
            }

        return try newBuilder.build()
    }
}
