// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension
import Partout

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var ctx: PartoutLoggerContext?

    private var fwd: NEPTPForwarder?

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        do {
            // NetworkExtension specifics
            let controller = try await NETunnelController(
                provider: self,
                decoder: .shared,
                registry: .shared,
                options: .init(),
                environmentFactory: { _ in
                    Demo.tunnelEnvironment
                }
            )

            var loggerBuilder = PartoutLogger.Builder()
            loggerBuilder.setDestination(OSLogDestination(.core), for: [.core])
            loggerBuilder.setDestination(OSLogDestination(.openvpn), for: [.openvpn])
            loggerBuilder.setDestination(OSLogDestination(.wireguard), for: [.wireguard])
            loggerBuilder.logsModules = true
            loggerBuilder.setLocalLogger(
                url: Demo.Log.tunnelURL,
                options: .init(
                    maxLevel: Demo.Log.maxLevel,
                    maxSize: Demo.Log.maxSize,
                    maxBufferedLines: Demo.Log.maxBufferedLines
                ),
                mapper: Demo.Log.formattedLine
            )
            PartoutLogger.register(loggerBuilder.build())

            let ctx = PartoutLoggerContext(controller.originalProfile.id)
            self.ctx = ctx

            fwd = try NEPTPForwarder(ctx, controller: controller)
            try await fwd?.startTunnel(options: options)
        } catch {
            flushLog()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await fwd?.stopTunnel(with: reason)
        fwd = nil
        flushLog()
    }

    override func cancelTunnelWithError(_ error: Error?) {
        flushLog()
        super.cancelTunnelWithError(error)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        await fwd?.handleAppMessage(messageData)
    }

    override func wake() {
        fwd?.wake()
    }

    override func sleep() async {
        await fwd?.sleep()
    }
}

private extension PacketTunnelProvider {
    func flushLog() {
        PartoutLogger.default.flushLog()
        Task {
            try? await Task.sleep(milliseconds: Demo.Log.saveInterval)
            flushLog()
        }
    }
}
