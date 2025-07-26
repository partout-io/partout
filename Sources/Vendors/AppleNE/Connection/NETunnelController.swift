// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@preconcurrency import NetworkExtension
import PartoutCore

/// Implementation of a ``/PartoutCore/TunnelController`` via `NEPacketTunnelProvider`.
public final class NETunnelController: TunnelController {
    public struct Options: Sendable {
        public var dnsFallbackServers: [String]

        public init() {
            dnsFallbackServers = []
        }
    }

    public private(set) weak var provider: NEPacketTunnelProvider?

    public let registry: Registry

    private let options: Options

    public let profile: Profile

    public let originalProfile: Profile

    public let environment: TunnelEnvironment

    public init(
        provider: NEPacketTunnelProvider,
        decoder: NEProtocolDecoder,
        registry: Registry,
        options: Options,
        environmentFactory: @escaping (Profile.ID) -> TunnelEnvironment,
        willProcess: ((Profile) async throws -> Profile)? = nil
    ) async throws {
        guard let tunnelConfiguration = provider.protocolConfiguration as? NETunnelProviderProtocol else {
            throw PartoutError(.decoding)
        }
        self.provider = provider
        self.registry = registry
        self.options = options
        originalProfile = try decoder.profile(from: tunnelConfiguration)
        let resolvedProfile = try registry.resolvedProfile(originalProfile)
        profile = try await willProcess?(resolvedProfile) ?? resolvedProfile
        environment = environmentFactory(profile.id)
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws {
        guard let provider else {
            logReleasedProvider()
            return
        }
        let tunnelSettings = profile.networkSettings(with: info, options: options)
        pp_log_id(profile.id, .ne, .info, "Commit tunnel settings: \(tunnelSettings)")
        try await provider.setTunnelNetworkSettings(tunnelSettings)
    }

    public func clearTunnelSettings() async {
        do {
            pp_log_id(profile.id, .ne, .info, "Clear tunnel settings")
            try await provider?.setTunnelNetworkSettings(nil)
        } catch {
            pp_log_id(profile.id, .ne, .error, "Unable to clear tunnel settings: \(error)")
        }
    }

    public func setReasserting(_ reasserting: Bool) {
        guard let provider else {
            logReleasedProvider()
            return
        }
        guard reasserting != provider.reasserting else {
            return
        }
        provider.reasserting = reasserting
    }

    public func cancelTunnelConnection(with error: Error?) {
        guard let provider else {
            logReleasedProvider()
            return
        }
        if let error {
            pp_log_id(profile.id, .ne, .fault, "Dispose tunnel: \(error)")
        } else {
            pp_log_id(profile.id, .ne, .notice, "Dispose tunnel")
        }
        provider.cancelTunnelWithError(error)
    }
}

private extension NETunnelController {
    func logReleasedProvider() {
        pp_log_id(profile.id, .ne, .info, "NETunnelController: NEPacketTunnelProvider released")
    }
}
