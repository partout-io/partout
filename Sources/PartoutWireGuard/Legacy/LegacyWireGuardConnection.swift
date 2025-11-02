// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//  SPDX-License-Identifier: MIT
//  Copyright © 2018-2024 WireGuard LLC. All Rights Reserved.

import NetworkExtension
import os
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Establishes a WireGuard connection. Legacy Apple-only implementation.
@available(*, deprecated, message: "Use WireGuardConnection")
public final class LegacyWireGuardConnection: Connection, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let statusSubject: CurrentValueStream<ConnectionStatus>

    private let moduleId: UniqueID

    private let controller: TunnelController

    private let environment: TunnelEnvironment

    private let tunnelConfiguration: TunnelConfiguration

    private let dataCountTimerInterval: TimeInterval

    private var dataCountTimer: Task<Void, Error>?

    private lazy var adapter: LegacyWireGuardAdapter = {
        LegacyWireGuardAdapter(with: delegate, backend: WireGuardBackend()) { [weak self] logLevel, message in
            pp_log(self?.ctx ?? .global, .wireguard, logLevel.debugLevel, message)
        }
    }()

    private lazy var delegate: LegacyWireGuardAdapterDelegate = AdapterDelegate(ctx, connection: self)

    public init(
        _ ctx: PartoutLoggerContext,
        parameters: ConnectionParameters,
        module: WireGuardModule
    ) throws {
        self.ctx = ctx
        statusSubject = CurrentValueStream(.disconnected)
        moduleId = module.id
        controller = parameters.controller
        environment = parameters.environment

        guard let configuration = module.configuration else {
            fatalError("No WireGuard configuration defined?")
        }
        pp_log(ctx, .wireguard, .notice, "WireGuard: Using legacy connection")

        let tweakedConfiguration = try configuration.withModules(from: parameters.profile)
        tunnelConfiguration = try tweakedConfiguration.toWireGuardConfiguration()

        dataCountTimerInterval = TimeInterval(parameters.options.minDataCountInterval) / 1000.0
    }

    public var statusStream: AsyncThrowingStream<ConnectionStatus, Error> {
        statusSubject.subscribeThrowing()
    }

    public func start() async throws -> Bool {
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
                await MainActor.run { [weak self] in
                    self?.onDataCountTimer()
                }
                try await Task.sleep(interval: dataCountTimerInterval)
            }
        }

        do {
            try await withUnsafeThrowingContinuation { [weak self] continuation in
                guard let self else {
                    continuation.resume()
                    return
                }
                adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    if let adapterError {
                        switch adapterError {
                        case .cannotLocateTunnelFileDescriptor:
                            pp_log(ctx, .wireguard, .error, "Starting tunnel failed: could not determine file descriptor")
                            continuation.resume(throwing: LegacyWireGuardConnectionError.couldNotDetermineFileDescriptor)

                        case .dnsResolution(let dnsErrors):
                            let hostnamesWithDnsResolutionFailure = dnsErrors.map(\.address)
                                .joined(separator: ", ")
                            pp_log(ctx, .wireguard, .error, "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
                            continuation.resume(throwing: LegacyWireGuardConnectionError.dnsResolutionFailure)

                        case .setNetworkSettings(let error):
                            pp_log(ctx, .wireguard, .error, "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                            continuation.resume(throwing: LegacyWireGuardConnectionError.couldNotSetNetworkSettings)

                        case .startWireGuardBackend(let errorCode):
                            pp_log(ctx, .wireguard, .error, "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                            continuation.resume(throwing: LegacyWireGuardConnectionError.couldNotStartBackend)

                        case .invalidState:
                            // Must never happen
                            fatalError()
                        }
                        return
                    }
                    let interfaceName = self.adapter.interfaceName ?? "unknown"
                    pp_log(ctx, .wireguard, .info, "Tunnel interface is \(interfaceName)")
                    continuation.resume()
                }
            }
            return true
        } catch {
            statusSubject.send(.disconnected)
            throw error
        }
    }

    public func stop(timeout: Int) async {
        pp_log(ctx, .wireguard, .info, "Stop tunnel")
        statusSubject.send(.disconnecting)

        // XXX: WireGuard adapter timeout unhandled (done in Cross though)

        await withCheckedContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume()
                return
            }
            self.adapter.stop { error in
                if let error {
                    pp_log(self.ctx, .wireguard, .error, "Unable to stop WireGuard adapter: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
        statusSubject.send(.disconnected)
    }
}

// MARK: - WireGuardAdapterDelegate

private extension LegacyWireGuardConnection {
    final class AdapterDelegate: LegacyWireGuardAdapterDelegate {
        private let ctx: PartoutLoggerContext

        private weak var connection: LegacyWireGuardConnection?

        init(_ ctx: PartoutLoggerContext, connection: LegacyWireGuardConnection) {
            self.ctx = ctx
            self.connection = connection
        }

        func adapterShouldReassert(_ adapter: LegacyWireGuardAdapter, reasserting: Bool) {
            if reasserting {
                connection?.statusSubject.send(.connecting)
            }
        }

        func adapterShouldSetNetworkSettings(_ adapter: LegacyWireGuardAdapter, settings: NEPacketTunnelNetworkSettings, completionHandler: (@Sendable (Error?) -> Void)?) {
            guard let connection else {
                pp_log(ctx, .wireguard, .error, "Lost weak reference to connection?")
                return
            }
            let module = TransientModule(object: settings)
            let addressObject = Address(rawValue: settings.tunnelRemoteAddress)
            if addressObject == nil {
                pp_log(ctx, .wireguard, .error, "Unable to parse remote tunnel address")
            }

            Task {
                do {
                    _ = try await connection.controller.setTunnelSettings(with: TunnelRemoteInfo(
                        originalModuleId: connection.moduleId,
                        address: addressObject,
                        modules: [module],
                        fileDescriptors: []
                    ))
                    completionHandler?(nil)
                    pp_log(connection.ctx, .wireguard, .info, "Tunnel interface is now UP")
                    connection.statusSubject.send(.connected)
                } catch {
                    completionHandler?(error)
                    pp_log(connection.ctx, .wireguard, .error, "Unable to configure tunnel settings: \(error)")
                    connection.statusSubject.send(.disconnected)
                }
            }
        }
    }
}

// MARK: - Data count

private extension LegacyWireGuardConnection {
    func onDataCountTimer() {
        guard statusSubject.value == .connected else {
            return
        }
        adapter.getRuntimeConfiguration { [weak self] configurationString in
            guard let configurationString = configurationString,
                  let dataCount = DataCount.from(wireGuardString: configurationString) else {
                return
            }
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

        guard let bytesReceived, let bytesSent else {
            return nil
        }

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

        return try newBuilder.build()
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
