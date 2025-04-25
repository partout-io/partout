//
//  NETunnelStrategy.swift
//  Partout
//
//  Created by Davide De Rosa on 10/10/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import NetworkExtension
import PartoutCore

/// Tunnel strategy based on `NETunnelProviderManager`.
public actor NETunnelStrategy {
    private let bundleIdentifier: String

    private let coder: NEProtocolCoder

    private let environment: TunnelEnvironment

    private nonisolated let managersSubject: CurrentValueStream<[Profile.ID: NETunnelProviderManager]>

    private nonisolated let currentManagerSubject: CurrentValueStream<NETunnelProviderManager?>

    private var allManagers: [Profile.ID: NETunnelProviderManager] {
        didSet {
            updateCurrentManager()
        }
    }

    private var pendingSaveTask: Task<Void, Error>?

    public init(
        bundleIdentifier: String,
        coder: NEProtocolCoder,
        environment: TunnelEnvironment
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.coder = coder
        self.environment = environment
        managersSubject = CurrentValueStream([:])
        currentManagerSubject = CurrentValueStream(nil)
        allManagers = [:]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNConfigurationChange),
            name: .NEVPNConfigurationChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNStatus),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - TunnelObservableStrategy

extension NETunnelStrategy: TunnelObservableStrategy {
    public func prepare(purge: Bool) async throws {
        try await reloadAllManagers(andPublish: true)
        if purge {
            await coder.purge(managers: Array(allManagers.values))
        }
    }

    public func install(
        _ profile: Profile,
        connect: Bool,
        options: TunnelStrategyConnectionOptions?,
        title: @escaping (Profile) -> String
    ) async throws {

        // disconnect before connect to work around macOS bug
        // resulting in multiple calls to startTunnel() to then
        // call stopTunnel() after 5s with reason .superceded
        //
        // TODO: #passepartout/218, do not disconnect active tunnel on macOS
        // it's not a bug, it's the intended behavior (yet poorly documented)
        // rework PTP to handle multiple calls to startTunnel()/stopTunnel() in
        // the same process
        if connect, let currentManager {
            let status = currentManager.connection.status.asTunnelStatus
            if status != .inactive || currentManager.isOnDemandEnabled == true {
                pp_log(.ne, .notice, "Disconnect active connection...")
                try await disconnect()
                pp_log(.ne, .notice, "Disconnection complete!")
            }
        }

        try await save(profile, forConnecting: connect, options: options?.values, title: title)
    }

    public func uninstall(profileId: Profile.ID) async throws {
        try await remove(profileId: profileId)
    }

    public func disconnect() async throws {
        guard let manager = currentManager else {
            return
        }
        try await saveAtomically(manager) {
            $0.isOnDemandEnabled = false
        }
        manager.connection.stopVPNTunnel()
        await manager.connection.waitForDisconnection()
    }

    public func sendMessage(_ message: Data) async throws -> Data? {
        guard let manager = currentManager else {
            return nil
        }
        try await manager.loadFromPreferences()
        guard let session = manager.connection as? NETunnelProviderSession else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public nonisolated var currentProfile: TunnelCurrentProfile? {
        currentManager?.asCurrentProfile
    }

    public nonisolated var didSetCurrent: AsyncStream<TunnelCurrentProfile?> {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let stream = currentManagerSubject.subscribe().dropFirst()
                var previousValue: TunnelCurrentProfile?
                for await manager in stream {
                    guard !Task.isCancelled else {
                        pp_log(.ne, .debug, "Cancelled NETunnelStrategy.didSetCurrent")
                        break
                    }
                    let newValue = manager?.asCurrentProfile
                    guard newValue != previousValue else {
                        continue
                    }
                    pp_log(.ne, .debug, "NETunnelStrategy.currentProfile -> \(newValue.debugDescription)")
                    continuation.yield(newValue)
                    previousValue = newValue
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - NETunnelManagerRepository

extension NETunnelStrategy: NETunnelManagerRepository {
    public func fetch() async throws -> [NETunnelProviderManager] {
        try await reloadAllManagers(andPublish: false)
        let managers = Array(allManagers.values)
        await coder.purge(managers: managers)
        return managers
    }

    public func save(
        _ profile: Profile,
        forConnecting: Bool,
        options: [String: NSObject]?,
        title: (Profile) -> String
    ) async throws {
        profile.log(.ne, .notice, withPreamble: "Encoded profile:")

        let proto = try coder.protocolConfiguration(
            from: profile,
            title: title
        )

        // store custom data on the side
        proto.profileId = profile.id

        let manager: NETunnelProviderManager
        do {
            manager = try await saveAtomically(profile.id) {
                $0.localizedDescription = profile.name
                $0.protocolConfiguration = proto

                let shouldEnableOnDemand: Bool
                if profile.isInteractive {
                    shouldEnableOnDemand = false
                } else if let onDemandModule = profile.firstModule(ofType: OnDemandModule.self, ifActive: true) {
                    let rules = onDemandModule.neRules
                    if !rules.isEmpty {
                        $0.onDemandRules = rules
                    } else {
                        $0.onDemandRules = [NEOnDemandRuleConnect()]
                    }
                    shouldEnableOnDemand = true
                } else {
                    shouldEnableOnDemand = false
                }

                // do not alter these two flags unless connecting explicitly
                $0.isEnabled = forConnecting || $0.isEnabled
                $0.isOnDemandEnabled = (forConnecting || $0.isOnDemandEnabled) && shouldEnableOnDemand
            }
        } catch {

            // revert adds, retain updates
            if allManagers[profile.id] == nil {
                try? coder.removeProfile(withId: profile.id)
            }

            throw error
        }

        if forConnecting {
            try manager.connection.startVPNTunnel(options: options)
        }
    }

    public func remove(profileId: Profile.ID) async throws {
        guard let manager = allManagers[profileId] else {
            return
        }
        try await manager.removeFromPreferences()
        allManagers.removeValue(forKey: profileId)
        try? coder.removeProfile(withId: profileId)
    }

    public nonisolated func profile(from manager: NETunnelProviderManager) throws -> Profile {
        guard let proto = manager.tunnelProtocol else {
            throw PartoutError(.decoding)
        }
        return try coder.profile(from: proto)
    }

    public nonisolated var managersStream: AsyncStream<[Profile.ID: NETunnelProviderManager]> {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                for await value in managersSubject.subscribe().dropFirst() {
                    guard !Task.isCancelled else {
                        pp_log(.ne, .debug, "Cancelled NETunnelStrategy.managersStream")
                        break
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Notifications

private extension NETunnelStrategy {

    @objc
    nonisolated func onVPNConfigurationChange(_ notification: Notification) {
        guard let manager = notification.object as? NETunnelProviderManager,
              manager.tunnelBundleIdentifier == bundleIdentifier,
              let profileId = manager.tunnelProtocol?.profileId else {
            return
        }

        pp_log(.ne, .debug, "NEVPNConfigurationChange(\(profileId)): \(notification)")
        Task {
            do {
                try await reloadAllManagers(andPublish: true)
            } catch {
                pp_log(.ne, .error, "Unable to reload managers: \(error)")
            }
        }
    }

    @objc
    nonisolated func onVPNStatus(_ notification: Notification) {
        guard let connection = notification.object as? NETunnelProviderSession,
              let manager = connection.manager as? NETunnelProviderManager,
              manager.tunnelBundleIdentifier == bundleIdentifier,
              let profileId = manager.tunnelProtocol?.profileId else {
            return
        }

//        pp_log(.ne, .debug, "NEVPNStatusDidChange: \(notification)")
        pp_log(.ne, .debug, "NEVPNStatus(\(profileId)) -> \(connection.status.rawValue)")
        Task {
            await updateCurrentManagerIfNeeded(with: manager, profileId: profileId)
        }
    }
}

// MARK: - Concurrency

private extension NETunnelStrategy {
    func saveAtomically(
        _ profileId: Profile.ID,
        block: @escaping (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        try await saveAtomically(
            self.allManagers[profileId] ?? NETunnelProviderManager(),
            block: block
        )
    }

    @discardableResult
    func saveAtomically(
        _ managerBlock: @escaping @autoclosure () -> NETunnelProviderManager,
        block: @escaping (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        if let pendingSaveTask {
            try await pendingSaveTask.value
        }
        let manager = managerBlock()
        pendingSaveTask = Task {
            try await manager.loadFromPreferences()
            try Task.checkCancellation()
            block(manager)
            try Task.checkCancellation()
            try await manager.saveToPreferences()
        }
        try await pendingSaveTask?.value
        pendingSaveTask = nil
        return manager
    }
}

// MARK: - Current manager

private extension NETunnelStrategy {
    nonisolated var currentManager: NETunnelProviderManager? {
        get {
            currentManagerSubject.value
        }
        set {
            currentManagerSubject.send(newValue)
        }
    }

    func reloadAllManagers(andPublish: Bool) async throws {
        var removedManagers = allManagers

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        allManagers = managers.reduce(into: [:]) {
            guard $1.tunnelBundleIdentifier == bundleIdentifier else {
                $1.removeFromPreferences()
                return
            }
            guard let profileId = $1.tunnelProtocol?.profileId else {
                $1.removeFromPreferences()
                return
            }
            $0[profileId] = $1
            removedManagers.removeValue(forKey: profileId)
        }

        // clean up coder data of removed managers
        removedManagers.forEach {
            try? coder.removeProfile(withId: $0.key)
        }

        logManagers()
        if andPublish {
            managersSubject.send(allManagers)
        }
    }

    func updateCurrentManager() {
        guard !allManagers.values.allSatisfy({ $0.rank == 0 }) else {
            currentManager = nil
            return
        }
        if let newManager = allManagers.values.max(by: { $0.rank < $1.rank }), newManager.rank > 0 {
            currentManager = newManager
        } else {
            currentManager = nil
        }
    }

    func updateCurrentManagerIfNeeded(with manager: NETunnelProviderManager, profileId: Profile.ID) {

        // deletion
        if allManagers.keys.contains(profileId), manager.connection.status == .invalid {
            allManagers.removeValue(forKey: profileId)
        }
        // update
        else {
            allManagers[profileId] = manager
        }
    }

    func logManagers() {
        if !allManagers.isEmpty {
            pp_log(.ne, .debug, "NETunnelStrategy.allManagers:")
        } else {
            pp_log(.ne, .debug, "NETunnelStrategy.allManagers: none")
        }
        allManagers.values.forEach {
            guard let profileId = $0.tunnelProtocol?.profileId else {
                return
            }
            pp_log(.ne, .debug, "\t\($0.localizedDescription ?? "")(\(profileId)): isEnabled=\($0.isEnabled), isOnDemandEnabled=\($0.isOnDemandEnabled), status=\($0.connection.status), rank=\($0.rank)")
        }
    }
}

private extension NETunnelProviderManager {
    var rank: Int {
#if os(iOS)
        // only one profile at a time is enabled on iOS
        if isEnabled {
            return .max
        }
#endif
        if ![.disconnected, .invalid].contains(connection.status) {
            return 2
        }
        if isOnDemandEnabled {
            return 1
        }
        return 0
    }

    var isStopping: Bool {
        [.disconnecting, .disconnected, .invalid].contains(connection.status)
    }
}

// MARK: - Profile ID

private enum CustomProviderKey: String {
    case profileId

    var key: String {
        "CustomProviderKey.\(rawValue)"
    }
}

private extension NETunnelProviderManager {
    var profileId: Profile.ID? {
        tunnelProtocol?.profileId
    }
}

private extension NETunnelProviderProtocol {
    var profileId: UUID? {
        get {
            guard let uuidString = providerConfiguration?[CustomProviderKey.profileId.key] as? String else {
                return nil
            }
            return UUID(uuidString: uuidString)
        }
        set {
            var cfg = providerConfiguration ?? [:]
            cfg[CustomProviderKey.profileId.key] = newValue?.uuidString
            providerConfiguration = cfg
        }
    }
}

private extension NETunnelProviderManager {
    var tunnelProtocol: NETunnelProviderProtocol? {
        protocolConfiguration as? NETunnelProviderProtocol
    }

    var tunnelBundleIdentifier: String? {
        tunnelProtocol?.providerBundleIdentifier
    }
}

// MARK: - Helpers

private extension NEVPNConnection {
    func waitForDisconnection() async {
        if status == .disconnected {
            return
        }
        for await notification in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
            guard let connection = notification.object as? NETunnelProviderSession,
                  connection === self else {
                continue
            }
            if [.disconnected, .invalid].contains(connection.status) {
                return
            }
        }
    }
}

private extension NETunnelProviderManager {
    var asCurrentProfile: TunnelCurrentProfile? {
        guard let profileId else {
            return nil
        }
        return TunnelCurrentProfile(
            id: profileId,
            status: connection.status.asTunnelStatus,
            onDemand: isEnabled && isOnDemandEnabled
        )
    }
}

private extension NEVPNStatus {
    var asTunnelStatus: TunnelStatus {
        switch self {
        case .connecting, .reasserting:
            return .activating

        case .connected:
            return .active

        case .disconnecting:
            return .deactivating

        case .disconnected, .invalid:
            return .inactive

        @unknown default:
            return .inactive
        }
    }
}
