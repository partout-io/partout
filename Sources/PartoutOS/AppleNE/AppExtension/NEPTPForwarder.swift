// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Delegates behavior of a `NEPacketTunnelProvider`.
public actor NEPTPForwarder {
    private let ctx: PartoutLoggerContext

    private let daemon: SimpleConnectionDaemon

    public nonisolated var profile: Profile {
        daemon.profile
    }

    public nonisolated var environment: TunnelEnvironment {
        daemon.environment
    }

    public init(
        _ ctx: PartoutLoggerContext,
        profile: Profile,
        registry: Registry,
        controller: NETunnelController,
        environment: TunnelEnvironment,
        factoryOptions: NEInterfaceFactory.Options = .init(),
        connectionOptions: ConnectionParameters.Options = .init(),
        stopDelay: Int = 2000,
        reconnectionDelay: Int = 2000
    ) throws {
        guard let provider = controller.provider else {
            pp_log(ctx, .os, .info, "NEPTPForwarder: NEPacketTunnelProvider released")
            throw PartoutError(.releasedObject)
        }
        let factory = NEInterfaceFactory(ctx, provider: provider, options: factoryOptions)
        let reachability = NEObservablePath(ctx)

        let connectionParameters = ConnectionParameters(
            profile: profile,
            controller: controller,
            factory: factory,
            reachability: reachability,
            environment: environment,
            options: connectionOptions
        )
        let messageHandler = DefaultMessageHandler(ctx, environment: environment)

        let params = SimpleConnectionDaemon.Parameters(
            registry: registry,
            connectionParameters: connectionParameters,
            reachability: reachability,
            messageHandler: messageHandler,
            stopDelay: stopDelay,
            reconnectionDelay: reconnectionDelay
        )

        self.ctx = ctx
        daemon = try SimpleConnectionDaemon(params: params)
    }

    deinit {
        pp_log(ctx, .os, .info, "Deinit PTP")
    }

    public func startTunnel(options: [String: NSObject]?) async throws {
        pp_log(ctx, .os, .notice, "Start PTP")
        try await daemon.start()
    }

    public func holdTunnel() async {
        pp_log(ctx, .os, .notice, "Hold PTP")
        await daemon.hold()
    }

    public func stopTunnel(with reason: NEProviderStopReason) async {
        pp_log(ctx, .os, .notice, "Stop PTP, reason: \(String(describing: reason))")
        await daemon.stop()
    }

    public func handleAppMessage(_ messageData: Data) async -> Data? {
        pp_log(ctx, .os, .debug, "Handle PTP message")
        do {
            let input = try JSONDecoder().decode(Message.Input.self, from: messageData)
            let output = try await daemon.sendMessage(input)
            let encodedOutput = try JSONEncoder().encode(output)
            switch input {
            case .environment:
                break
            default:
                pp_log(ctx, .os, .info, "Message handled and response encoded (\(encodedOutput.asSensitiveBytes(ctx)))")
            }
            return encodedOutput
        } catch {
            pp_log(ctx, .os, .error, "Unable to decode message: \(messageData)")
            return nil
        }
    }

    public func sleep() async {
        pp_log(ctx, .os, .debug, "Device is about to sleep")
    }

    public nonisolated func wake() {
        pp_log(ctx, .os, .debug, "Device is about to wake up")
    }
}
