// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@preconcurrency import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension Profile {
    public init(withNEProvider provider: NETunnelProvider, decoder: NEProtocolDecoder) throws {
        guard let tunnelConfiguration = provider.protocolConfiguration as? NETunnelProviderProtocol else {
            pp_log_g(.ne, .error, "Unable to parse profile from NETunnelProviderProtocol")
            throw PartoutError(.decoding)
        }
        do {
            self = try decoder.profile(from: tunnelConfiguration)
        } catch {
            pp_log_g(.ne, .error, "Unable to decode and process profile: \(error)")
            throw error
        }
    }
}

/// Implementation of a ``/PartoutCore/TunnelController`` via `NEPacketTunnelProvider`.
public final class NETunnelController: TunnelController {
    public struct Options: Sendable {
        public var dnsFallbackServers: [String]

        public init() {
            dnsFallbackServers = []
        }
    }

    nonisolated(unsafe)
    public private(set) weak var provider: NEPacketTunnelProvider?

    private let profile: Profile

    private let options: Options

    private let tun: NETunnelInterface

    public init(
        provider: NEPacketTunnelProvider,
        profile: Profile,
        options: Options
    ) async throws {
        self.provider = provider
        self.profile = profile
        self.options = options
        tun = NETunnelInterface(.init(profile.id), impl: provider.packetFlow)
    }

    public func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface {
        guard let provider else {
            logReleasedProvider()
            throw PartoutError(.releasedObject)
        }
        let tunnelSettings = profile.networkSettings(with: info, options: options)
        pp_log_id(profile.id, .ne, .info, "Commit tunnel settings: \(tunnelSettings)")
        try await provider.setTunnelNetworkSettings(tunnelSettings)

        return tun
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
