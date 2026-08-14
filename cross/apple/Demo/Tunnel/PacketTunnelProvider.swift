// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension
import PartoutRuntime

extension NSObject: @retroactive @unchecked Sendable {}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var ctx: PartoutLoggerContext?

    private var runtime: PartoutProviderRuntime?

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        do {
            let profile = try Profile(withNEProvider: self, decoder: .shared)
            runtime = try PartoutProviderRuntime(
                provider: self,
                profile: profile,
                options: .init(
                    dnsFallbackServers: [],
                    logsSnapshots: false
                ),
                defaults: Demo.tunnelDefaults,
                logsPrivateData: false,
                cacheDir: FileManager.default.temporaryDirectory.path(),
                minDataCountDelta: 0,
                logger: logger
            )

            var loggerBuilder = PartoutLogger.Builder()
            loggerBuilder.setDestination(OSLogDestination(.abi), for: [.abi])
            loggerBuilder.setDestination(OSLogDestination(.core), for: [.core])
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

            let ctx = PartoutLoggerContext(profile.id)
            self.ctx = ctx

            try await runtime?.startTunnel()
        } catch {
            flushLog()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await runtime?.stopTunnel()
        runtime = nil
        flushLog()
    }

    override func cancelTunnelWithError(_ error: Error?) {
        flushLog()
        super.cancelTunnelWithError(error)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        await runtime?.handleAppMessage(messageData)
    }

    override func wake() {
        runtime?.wake()
    }

    override func sleep() async {
        await runtime?.sleep()
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

private nonisolated func logger(
    _ level: Int32,
    _ message: UnsafePointer<CChar>?
) {
    guard let level = DebugLog.Level(rawValue: Int(level)),
          let message else { return }
    pp_log(.global, .abi, level, String(cString: message))
}
