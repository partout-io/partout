// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//  SPDX-License-Identifier: MIT
//  Copyright © 2018-2024 WireGuard LLC. All Rights Reserved.

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public actor WireGuardConnection: Connection {
    private let ctx: PartoutLoggerContext

    private let statusSubject: CurrentValueStream<ConnectionStatus>

    private let moduleId: UniqueID

    private let controller: TunnelController

    private let reachability: ReachabilityObserver

    private let environment: TunnelEnvironment

    private let tunnelConfiguration: WireGuard.Configuration

    private let dataCountTimerInterval: TimeInterval

    private var dataCountTimer: Task<Void, Error>?

    private var adapter: WireGuardAdapter?

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

        guard let configuration = module.configuration else {
            fatalError("No WireGuard configuration defined?")
        }
        pp_log(ctx, .wireguard, .notice, "WireGuard: Using cross-platform connection")

        tunnelConfiguration = try configuration.withModules(from: parameters.profile)
        dataCountTimerInterval = TimeInterval(parameters.options.minDataCountInterval) / 1000.0
    }

    deinit {
        pp_log(ctx, .wireguard, .info, "Deinit WireGuardConnection")
    }

    public nonisolated var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject.subscribeThrowing()
    }

    public func start() async throws -> Bool {
        assert(adapter == nil)
        adapter = await WireGuardAdapter(
            ctx,
            with: self,
            moduleId: moduleId,
            reachability: reachability,
            logHandler: { [weak self] logLevel, message in
                pp_log(self?.ctx ?? .global, .wireguard, logLevel.debugLevel, message)
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
                    pp_log(ctx, .wireguard, .debug, "Cancelled WireGuardConnection.dataCountTimer")
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
        // FIXME: #199, handle WireGuard adapter timeout
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

// MARK: - WireGuardAdapterDelegate

extension WireGuardConnection: WireGuardAdapterDelegate {
    nonisolated func adapterShouldReassert(_ adapter: WireGuardAdapter, reasserting: Bool) {
        if reasserting {
            statusSubject.send(.connecting)
        }
    }

    func adapterShouldSetNetworkSettings(_ adapter: WireGuardAdapter, settings: TunnelRemoteInfo) async throws -> IOInterface {
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

    nonisolated func adapterShouldConfigureSockets(_ adapter: WireGuardAdapter, descriptors: [UInt64]) {
        controller.configureSockets(with: descriptors)
    }

    func adapterShouldClearNetworkSettings(_ adapter: WireGuardAdapter, tunnel: IOInterface) async {
        await controller.clearTunnelSettings(tunnel)
    }
}

// MARK: - Data count

private extension WireGuardConnection {
    func onDataCountTimer() async {
        guard let adapter else { return }
        guard statusSubject.value == .connected else { return }
        guard let configurationString = await adapter.getRuntimeConfiguration(),
              let dataCount = DataCount.from(wireGuardString: configurationString) else {
            return
        }
        await MainActor.run { [weak self] in
            self?.environment.setEnvironmentValue(dataCount, forKey: TunnelEnvironmentKeys.dataCount)
        }
    }
}

private extension DataCount {
    static func from(wireGuardString string: String) -> DataCount? {
        var bytesReceived: UInt?
        var bytesSent: UInt?
        string.enumerateLines { line, stop in
            if bytesReceived == nil, let value = line.getPrefix("rx_bytes=") {
                bytesReceived = value
            } else if bytesSent == nil, let value = line.getPrefix("tx_bytes=") {
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
    func getPrefix(_ prefixKey: String) -> UInt? {
        guard hasPrefix(prefixKey) else {
            return nil
        }
        return UInt(dropFirst(prefixKey.count))
    }
}

// MARK: - Helpers

private extension WireGuard.Configuration {
    func withModules(from profile: Profile) throws -> Self {
        var newBuilder = builder()

        // add IPModule.*.includedRoutes to AllowedIPs
        profile.activeModules
            .compactMap {
                $0 as? IPModule
            }
            .forEach { ipModule in
                newBuilder.peers = peers
                    .map { oldPeer in
                        var peer = oldPeer.builder()
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
                newBuilder.peers = peers
                    .map { oldPeer in
                        var peer = oldPeer.builder()
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

        return try newBuilder.tryBuild()
    }
}

private extension WireGuardLogLevel {
    var debugLevel: DebugLog.Level {
        switch self {
        case .verbose:
            return .debug

        case .error:
            return .error
        }
    }
}
