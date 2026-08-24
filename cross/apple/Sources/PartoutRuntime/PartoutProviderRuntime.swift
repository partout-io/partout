// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

public final class PartoutProviderRuntime: Sendable {
    private let ctx: PartoutLoggerContext
    public let profile: Profile
    public let environment: UserDefaultsEnvironment
    private let controller: PartoutTunnelController
    private let messageHandler: DefaultMessageHandler
    private let options: TunnelControllerOptions
    private let logsPrivateData: Bool
    private let cacheDir: String?
    private let minDataCountDelta: Int64?
    private let logger: partout_logger_cb?

    public init(
        provider: NEPacketTunnelProvider,
        profile: Profile,
        options: TunnelControllerOptions,
        defaults: UserDefaults,
        logsPrivateData: Bool,
        cacheDir: String? = nil,
        minDataCountDelta: Int64? = nil,
        logger: partout_logger_cb?
    ) throws {
        ctx = PartoutLoggerContext(profile.id)
        self.profile = profile
        let environment = UserDefaultsEnvironment(profileId: profile.id, defaults: defaults)
        self.environment = environment
        controller = PartoutTunnelController(
            ctx,
            provider: provider,
            options: options,
            environment: environment
        )
        messageHandler = DefaultMessageHandler(ctx, environment: environment)
        self.options = options
        self.logsPrivateData = logsPrivateData
        self.cacheDir = cacheDir
        self.minDataCountDelta = minDataCountDelta
        self.logger = logger
    }

    deinit {
        pp_log(ctx, .runtime, .debug, "Deinit runtime")
    }

    public func startTunnel() async throws {
        pp_log(ctx, .runtime, .notice, "Start runtime")

        var init_args = partout_init_args(
            logs_private_data: logsPrivateData,
            logger: logger
        )
        pp_log(ctx, .runtime, .info, "Initialize Partout library")
        partout_init(&init_args)

        let profileJSON = try JSONEncoder.shared().encodeJSON(profile.asTaggedProfile)
        let loggedProfileJSON = profileJSON.debugDescription(withSensitiveData: logsPrivateData)
        pp_log(ctx, .runtime, .debug, "Profile JSON: \(loggedProfileJSON)")

        let retainedController = Unmanaged.passRetained(controller)
        let retainedEnvironment = Unmanaged.passRetained(environment)
        var bindings = partout_daemon_bindings(
            controller: retainedController.toOpaque(),
            events: .asDaemonEvents(retainedEnvironment.toOpaque()),
            release: { bindings in
                if let rawController = bindings?.pointee.controller {
                    Unmanaged<PartoutTunnelController>.fromOpaque(rawController).release()
                }
                if let rawEnvironment = bindings?.pointee.events.ctx {
                    Unmanaged<UserDefaultsEnvironment>.fromOpaque(rawEnvironment).release()
                }
            }
        )
        let result = profileJSON.withCString { profile in
            let cCacheDir = cacheDir?.withCString {
                strdup($0)
            }
            defer {
                free(cCacheDir)
            }
            let daemonOptions = partout_daemon_options(
                is_daemon: false,
                starts_immediately: false,
                cancels_unrecoverable: false,
                cache_dir: cCacheDir,
                min_data_count_delta: UInt64(minDataCountDelta ?? .zero)
            )
            return withUnsafePointer(to: &bindings) { bindingsPtr in
                var start_args = partout_daemon_start_args(
                    profile: profile,
                    options: daemonOptions,
                    bindings: bindingsPtr
                )
                return partout_daemon_start(&start_args)
            }
        }
        let cResult = partout_completion_code(result)
        switch cResult {
        case PartoutCompletionCodeOK:
            break
        default:
            pp_log(ctx, .runtime, .fault, "Unable to start runtime: result=\(cResult)")
            throw PartoutError(.invalidValue)
        }
        pp_log(ctx, .runtime, .notice, "Runtime started")
    }

    public func holdTunnel() async {
        pp_log(ctx, .runtime, .notice, "Hold runtime")
        partout_daemon_hold()
    }

    public func stopTunnel() async {
        pp_log(ctx, .runtime, .notice, "Stop runtime")
        partout_daemon_stop()
    }

    public func cancelTunnelWithError(_: Error?) {}

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
                pp_log(ctx, .runtime, .info, "Message handled and response encoded (\(encodedOutput.asSensitiveBytes(ctx)))")
            }
            return encodedOutput
        } catch {
            pp_log(ctx, .runtime, .error, "Unable to handle runtime message: \(error)")
            return nil
        }
    }

    public func sleep() async {
        pp_log(ctx, .runtime, .debug, "Runtime is about to sleep")
    }

    public nonisolated func wake() {
        pp_log(ctx, .runtime, .debug, "Runtime is about to wake up")
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
