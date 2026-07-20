// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(Darwin)
import NetworkExtension
import Partout_C
import Partout

public final class PartoutProviderRuntime: Sendable {
    private let ctx: PartoutLoggerContext
    public let profile: Profile
    private let controller: PartoutTunnelController
    private let environment: UserDefaultsEnvironment
    private let messageHandler: DefaultMessageHandler
    private let options: TunnelControllerOptions
    private let logger: partout_logger_cb?

    public init(
        provider: NEPacketTunnelProvider,
        decoder: NEProtocolDecoder,
        options: TunnelControllerOptions,
        defaults: UserDefaults,
        logger: partout_logger_cb?
    ) throws {
        profile = try Profile(withNEProvider: provider, decoder: decoder)
        ctx = PartoutLoggerContext(profile.id)
        controller = PartoutTunnelController(ctx, provider: provider, options: options)
        environment = UserDefaultsEnvironment(profileId: profile.id, defaults: defaults)
        messageHandler = DefaultMessageHandler(ctx, environment: environment)
        self.options = options
        self.logger = logger
    }

    deinit {
        pp_log(ctx, .os, .debug, "Deinit runtime")
    }

    public static var version: String {
        guard let cString = partout_version() else {
            return "undefined"
        }
        return String(cString: cString)
    }

    public func startTunnel() async throws {
        pp_log(ctx, .os, .notice, "Start runtime")

        var init_args = partout_init_args(
            logs_private_data: true,
            logger: logger
        )
        pp_log(ctx, .os, .info, "Initialize Partout library")
        partout_init(&init_args)

        let profileJSON = try JSONEncoder.shared().encodeJSON(profile.asTaggedProfile)
        pp_log(ctx, .os, .debug, "Profile JSON: \(profileJSON)")

        let retainedController = Unmanaged.passRetained(controller)
        let retainedEnvironment = Unmanaged.passRetained(environment)
        var bindings = partout_daemon_bindings(
            controller: retainedController.toOpaque(),
            events: .asDaemonEvents(retainedEnvironment.toOpaque()),
            release: { bindings in
                if let rawController = bindings?.pointee.controller {
                    Unmanaged<NETunnelController>.fromOpaque(rawController).release()
                }
                if let rawEnvironment = bindings?.pointee.events.ctx {
                    Unmanaged<UserDefaultsEnvironment>.fromOpaque(rawEnvironment).release()
                }
            }
        )
        let daemonOptions = partout_daemon_options(
            is_daemon: false,
            starts_immediately: false,
            cache_dir: nil,
            min_data_count_delta: options.minDataCountDelta
        )
        let result = profileJSON.withCString { profile in
            withUnsafePointer(to: &bindings) { bindingsPtr in
                var start_args = partout_daemon_start_args(
                    profile: profile,
                    options: daemonOptions,
                    bindings: bindingsPtr
                )
                return partout_daemon_start(&start_args)
            }
        }
        guard result == 0 else {
            retainedController.release()
            retainedEnvironment.release()
            pp_log(ctx, .os, .fault, "Unable to start runtime: result=\(result)")
            return
        }
        pp_log(ctx, .os, .notice, "Runtime started")
    }

    public func holdTunnel() async {
        pp_log(ctx, .os, .notice, "Hold runtime")
        partout_daemon_hold()
    }

    public func stopTunnel(with reason: NEProviderStopReason) async {
        pp_log(ctx, .os, .notice, "Stop runtime, reason: \(String(describing: reason))")
        partout_daemon_stop()
    }

    public func cancelTunnelWithError(_ error: Error?) {
        pp_log(ctx, .os, .info, "Cancel runtime, error: \(String(describing: error))")
        controller.cancelTunnelConnection(with: error)
    }

    public func handleAppMessage(_ messageData: Data) async -> Data? {
        do {
            let input = try JSONDecoder.shared().decode(Message.Input.self, from: messageData)
            guard let output = try await messageHandler.handleMessage(input) else {
                return nil
            }
            let encodedOutput = try JSONEncoder.shared().encode(output)
            switch input {
            case .environment:
                break
            default:
                pp_log(ctx, .os, .info, "Message handled and response encoded (\(encodedOutput.asSensitiveBytes(ctx)))")
            }
            return encodedOutput
        } catch {
            pp_log(ctx, .os, .error, "Unable to handle runtime message: \(error)")
            return nil
        }
    }

    public func sleep() async {
        pp_log(ctx, .os, .debug, "Runtime is about to sleep")
    }

    public nonisolated func wake() {
        pp_log(ctx, .os, .debug, "Runtime is about to wake up")
    }
}

private extension partout_daemon_events {
    static func asDaemonEvents(_ thiz: UnsafeMutableRawPointer) -> partout_daemon_events {
        partout_daemon_events(
            ctx: thiz,
            set_connection_status: setConnectionStatus,
            set_data_count: setDataCount,
            set_last_error_code: setLastErrorCode,
            remove: remove
        )
    }

    static let setConnectionStatus: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, status in
        guard let environment = environment(from: ctx), let status else {
            return
        }
        guard let value = ConnectionStatus(rawValue: String(cString: status)) else {
            return
        }
        environment.setEnvironmentValue(value, forKey: TunnelEnvironmentKeys.connectionStatus)
    }

    static let setDataCount: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Void = { ctx, received, sent in
        guard let environment = environment(from: ctx) else {
            return
        }
        environment.setEnvironmentValue(
            DataCount(received: received, sent: sent),
            forKey: TunnelEnvironmentKeys.dataCount
        )
    }

    static let setLastErrorCode: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, code in
        guard let environment = environment(from: ctx), let code else {
            return
        }
        environment.setEnvironmentValue(
            String(cString: code),
            forKey: TunnelEnvironmentKeys.lastErrorCode
        )
    }

    static let remove: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, key in
        guard let environment = environment(from: ctx), let key else {
            return
        }
        environment.removeEnvironmentValue(forKey: String(cString: key))
    }

    private static func environment(from ctx: UnsafeMutableRawPointer?) -> UserDefaultsEnvironment? {
        guard let ctx else {
            return nil
        }
        return Unmanaged<UserDefaultsEnvironment>.fromOpaque(ctx).takeUnretainedValue()
    }
}
#endif
