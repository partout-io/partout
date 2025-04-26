//
//  NEPTPForwarder.swift
//  Partout
//
//  Created by Davide De Rosa on 3/2/24.
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

/// Delegates behavior of a `NEPacketTunnelProvider`.
public actor NEPTPForwarder {
    private let daemon: SimpleConnectionDaemon

    public nonisolated var profile: Profile {
        daemon.profile
    }

    public let originalProfile: Profile

    public init(
        provider: NEPacketTunnelProvider,
        decoder: NEProtocolDecoder,
        registry: Registry,
        environment: TunnelEnvironment,
        factoryOptions: NEInterfaceFactory.Options = .init(),
        connectionOptions: ConnectionParameters.Options = .init(),
        stopDelay: Int = 2000,
        reconnectionDelay: Int = 2000,
        willProcess: ((Profile) async throws -> Profile)? = nil,
        willStart: (@Sendable (Profile) async throws -> Void)? = nil
    ) async throws {

        // NetworkExtension specifics
        let controller = try await NETunnelController(
            provider: provider,
            decoder: decoder,
            registry: registry,
            environment: environment,
            willProcess: willProcess
        )
        let factory = NEInterfaceFactory(provider: provider, options: factoryOptions)
        let reachability = NEObservablePath()

        let connectionParameters = ConnectionParameters(
            controller: controller,
            factory: factory,
            environment: environment,
            options: connectionOptions
        )
        let messageHandler = DefaultMessageHandler()

        let params = SimpleConnectionDaemon.Parameters(
            registry: registry,
            connectionParameters: connectionParameters,
            reachability: reachability,
            messageHandler: messageHandler,
            stopDelay: stopDelay,
            reconnectionDelay: reconnectionDelay,
            willStart: willStart
        )
        daemon = SimpleConnectionDaemon(params: params)
        originalProfile = controller.originalProfile
    }

    deinit {
        pp_log(.ne, .info, "Deinit PTP")
    }

    public func startTunnel(options: [String: NSObject]?) async throws {
        pp_log(.ne, .notice, "Start PTP")
        try await daemon.start()
    }

    public func holdTunnel() async {
        pp_log(.ne, .notice, "Hold PTP")
        await daemon.hold()
    }

    public func stopTunnel(with reason: NEProviderStopReason) async {
        pp_log(.ne, .notice, "Stop PTP, reason: \(String(describing: reason))")
        await daemon.stop()
    }

    public func handleAppMessage(_ messageData: Data) async -> Data? {
        pp_log(.ne, .notice, "Handle PTP message")
        do {
            let input = try JSONDecoder().decode(Message.Input.self, from: messageData)
            let output = try await daemon.sendMessage(input)
            let encodedOutput = try JSONEncoder().encode(output)
            pp_log(.ne, .notice, "Message handled and response encoded (\(encodedOutput.asSensitiveBytes))")
            return encodedOutput
        } catch {
            pp_log(.ne, .error, "Unable to decode message: \(messageData)")
            return nil
        }
    }

    public func sleep() async {
        pp_log(.ne, .debug, "Device is about to sleep")
    }

    public nonisolated func wake() {
        pp_log(.ne, .debug, "Device is about to wake up")
    }
}
