// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
import PartoutNative_C

/// A controller based on `NEPacketTunnelProvider`.
final class PartoutTunnelController: Sendable {
    private let ctx: PartoutLoggerContext
    nonisolated(unsafe)
    private weak var provider: NEPacketTunnelProvider?
    private let options: TunnelControllerOptions
    private let environment: any TunnelEnvironmentWriter
    private let networkMonitor: NetworkMonitor

    private let delegateLock = SemaphoreMutex()
    private nonisolated(unsafe) var delegate: partout_controller_delegate?

    init(
        _ ctx: PartoutLoggerContext,
        provider: NEPacketTunnelProvider,
        options: TunnelControllerOptions,
        environment: any TunnelEnvironmentWriter
    ) {
        self.ctx = ctx
        self.provider = provider
        self.options = options
        self.environment = environment

        networkMonitor = NetworkMonitor(ctx)

        let networkEvents = networkMonitor.events
        Task { [weak self] in
            for await event in networkEvents {
                switch event {
                case .reachability(let isReachable):
                    self?.onReachable(isReachable)
                case .betterPath:
                    self?.onBetterPath()
                }
            }
        }
        networkMonitor.start()
    }

    func setNetworkLoggingEnabled(_ enabled: Bool) {
        networkMonitor.setLoggingEnabled(enabled)
    }

    func onReachable(_ isReachable: Bool) {
        delegateLock.with {
            guard let delegate = self.delegate else { return }
            var reachability = partout_reachability(reachable: isReachable)
            withUnsafePointer(to: &reachability) {
                delegate.on_reachability?(delegate.ctx, $0)
            }
        }
    }

    func onBetterPath() {
        delegateLock.with {
            guard let delegate = self.delegate else { return }
            delegate.on_better_path?(delegate.ctx)
        }
    }

    func setTunnelSettings(with info: TunnelRemoteInfoWrapper) async throws {
        guard let provider else {
            logReleasedProvider()
            throw PartoutError(.releasedObject)
        }
        let profile = try info.profile.asProfile()
        let tunnelSettings = profile.networkSettings(with: info, options: options)
        pp_log(ctx, .runtime, .info, "Commit tunnel settings: \(tunnelSettings)")
        try await provider.setTunnelNetworkSettings(tunnelSettings)
    }

    func configureSockets(with descriptors: [SocketDescriptor]) {
    }

    func reportSnapshot(_ snapshot: TunnelSnapshot) {
        if options.logsSnapshots {
            pp_log(ctx, .runtime, .debug, "Report tunnel snapshot: \(snapshot)")
        }
        // The runtime already handles the connection events
        // to keep the tunnel environment up to date
    }

    func setEnvironmentData(_ value: Data?, forKey key: String) {
        environment.setEnvironmentData(value, forKey: key)
    }

    func clearTunnelSettings(withKillSwitch: Bool) async {
        // Do nothing, retain the routes to avoid temporary leaks
    }

    func setReasserting(_ reasserting: Bool) {
        guard let provider else {
            logReleasedProvider()
            return
        }
        guard reasserting != provider.reasserting else {
            return
        }
        provider.reasserting = reasserting
    }

    func cancelTunnelConnection(with error: Error?) {
        guard let provider else {
            logReleasedProvider()
            return
        }
        if let error {
            pp_log(ctx, .runtime, .fault, "Dispose tunnel with error: \(error)")
        } else {
            pp_log(ctx, .runtime, .notice, "Dispose tunnel")
        }
        provider.cancelTunnelWithError(error)
    }
}

private extension PartoutTunnelController {
    func logReleasedProvider() {
        pp_log(ctx, .runtime, .info, "NEPacketTunnelProvider released")
    }
}

// MARK: - C bindings

extension PartoutTunnelController {
    enum Bindings {
        static func setDelegate(_ ref: UnsafeMutableRawPointer?, delegate: UnsafeRawPointer?) {
            guard let controller = controller(from: ref) else {
                return
            }
            let copied = delegate?
                .assumingMemoryBound(to: partout_controller_delegate.self)
                .pointee

            controller.delegateLock.with {
                controller.delegate = copied
            }
            controller.onReachable(controller.networkMonitor.isReachable)
        }

        static func setTunnel(
            _ ref: UnsafeMutableRawPointer?,
            uuid: UnsafePointer<CChar>?,
            infoJSON: UnsafePointer<CChar>?
        ) -> Bool {
            guard let controller = controller(from: ref), let infoJSON else {
                return false
            }
            do {
                let info = try tunnelRemoteInfo(from: infoJSON)
                try blockUntilComplete {
                    try await controller.setTunnelSettings(with: info)
                }
                return true
            } catch {
                controller.logBridgeError("Unable to set tunnel settings", error)
                return false
            }
        }

        static func configureSockets(
            _ ref: UnsafeMutableRawPointer?,
            reachability: UnsafeRawPointer?,
            descriptors: UnsafePointer<Int32>?,
            descriptorsCount: Int
        ) -> Bool {
            _ = reachability
            guard let controller = controller(from: ref) else {
                return false
            }
            guard descriptorsCount >= 0 else {
                return false
            }
            let values: [SocketDescriptor]
            if let descriptors {
                values = Array(UnsafeBufferPointer(start: descriptors, count: descriptorsCount))
            } else {
                values = []
            }
            controller.configureSockets(with: values)
            return true
        }

        static func reportSnapshot(
            _ ref: UnsafeMutableRawPointer?,
            snapshotJSON: UnsafePointer<CChar>?
        ) {
            guard let controller = controller(from: ref), let snapshotJSON else {
                return
            }
            do {
                let snapshot = try JSONDecoder.shared().decode(
                    TunnelSnapshot.self,
                    from: Data(String(cString: snapshotJSON).utf8)
                )
                controller.reportSnapshot(snapshot)
            } catch {
                controller.logBridgeError("Unable to decode tunnel snapshot", error)
            }
        }

        static func setEnvironmentValue(
            _ ref: UnsafeMutableRawPointer?,
            key: UnsafePointer<CChar>?,
            value: UnsafePointer<CChar>?
        ) {
            guard let controller = controller(from: ref), let key else {
                return
            }
            let data = value.map {
                Data(String(cString: $0).utf8)
            }
            controller.setEnvironmentData(data, forKey: String(cString: key))
        }

        static func clearTunnel(_ ref: UnsafeMutableRawPointer?, killSwitch: Bool) {
            guard let controller = controller(from: ref) else {
                return
            }
            do {
                try blockUntilComplete {
                    await controller.clearTunnelSettings(withKillSwitch: killSwitch)
                }
            } catch {
                controller.logBridgeError("Unable to clear tunnel settings", error)
            }
        }

        static func cancelTunnel(_ ref: UnsafeMutableRawPointer?, errorCode: UnsafePointer<CChar>?) {
            guard let controller = controller(from: ref) else {
                return
            }
            let error: Error? = errorCode.map {
                let rawCode = String(cString: $0)
                if let error = PartoutError(rawValue: rawCode) {
                    return error
                }
                return PartoutError(.unhandled)
            }
            controller.cancelTunnelConnection(with: error)
        }

        private static func controller(from ref: UnsafeMutableRawPointer?) -> PartoutTunnelController? {
            guard let ref else {
                pp_log_g(.runtime, .error, "NETunnelController C bridge received a nil reference")
                return nil
            }
            return Unmanaged<PartoutTunnelController>.fromOpaque(ref).takeUnretainedValue()
        }

        private static func tunnelRemoteInfo(from infoJSON: UnsafePointer<CChar>) throws -> TunnelRemoteInfoWrapper {
            try JSONDecoder.shared().decode(
                TunnelRemoteInfoWrapper.self,
                from: Data(String(cString: infoJSON).utf8)
            )
        }
    }
}

extension PartoutTunnelController {
    static var functions: partout_controller_functions {
        partout_controller_functions(
            set_delegate: { ref, delegate in
                Bindings.setDelegate(ref, delegate: delegate.map(UnsafeRawPointer.init))
            },
            set_tunnel: { ref, uuid, infoJSON in
                guard Bindings.setTunnel(ref, uuid: uuid, infoJSON: infoJSON) else { return nil }
                return partout_tun_lookup()
            },
            report_snapshot: { ref, json in
                Bindings.reportSnapshot(ref, snapshotJSON: json)
            },
            set_environment_value: { ref, key, value in
                Bindings.setEnvironmentValue(ref, key: key, value: value)
            },
            clear_tunnel: { ref, killSwitch in
                Bindings.clearTunnel(ref, killSwitch: killSwitch)
            },
            cancel_tunnel: { ref, errorCode in
                Bindings.cancelTunnel(ref, errorCode: errorCode)
            },
            configure_sockets: { ref, reachability, descriptors, count in
                Bindings.configureSockets(ref, reachability: reachability.map(UnsafeRawPointer.init),
                                          descriptors: descriptors, descriptorsCount: count)
            }
        )
    }
}

private extension PartoutTunnelController {
    func logBridgeError(_ message: String, _ error: Error) {
        pp_log(ctx, .runtime, .error, "\(message): \(error)")
    }
}

private final class BlockingResult: @unchecked Sendable {
    var result: Result<Void, Error>?
}

private func blockUntilComplete(
    _ operation: @escaping @Sendable () async throws -> Void
) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let result = BlockingResult()
    Task.detached {
        do {
            try await operation()
            result.result = .success(())
        } catch {
            result.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    try result.result?.get()
}
