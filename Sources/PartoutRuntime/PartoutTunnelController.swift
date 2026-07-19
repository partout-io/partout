// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(Darwin)
internal import _PartoutPortable_C
import NetworkExtension
import Partout

/// A controller based on `NEPacketTunnelProvider`.
final class PartoutTunnelController: Sendable {
    private let ctx: PartoutLoggerContext
    nonisolated(unsafe)
    private weak var provider: NEPacketTunnelProvider?
    private let options: TunnelControllerOptions
    private let reachability: ReachabilityObserver
    private let betterPath: BetterPathStreamFactory

    private let delegateLock = SemaphoreMutex()
    private nonisolated(unsafe) var delegate: pp_tun_ctrl_delegate?

    init(
        _ ctx: PartoutLoggerContext,
        provider: NEPacketTunnelProvider,
        options: TunnelControllerOptions
    ) {
        self.ctx = ctx
        self.provider = provider
        self.options = options

        reachability = NEObservablePath(ctx)
        betterPath = NEBetterPathStreamFactory(ctx)

        let isReachableStream = reachability.isReachableStream
        let betterPathStream = betterPath.newStream().subscribe()
        Task { [weak self] in
            for await isReachable in isReachableStream {
                self?.onReachable(isReachable)
            }
        }
        Task { [weak self] in
            for await _ in betterPathStream {
                self?.onBetterPath()
            }
        }
        reachability.startObserving()
    }

    func onReachable(_ isReachable: Bool) {
        let delegate = delegateLock.with { self.delegate }
        guard let delegate else { return }

        var cReach = pp_reachability(reachable: isReachable)
        pp_log(ctx, .os, .debug, "On reachability: \(cReach)")
        withUnsafePointer(to: &cReach) {
            delegate.on_reachability(delegate.ctx, $0)
        }
    }

    func onBetterPath() {
        let delegate = delegateLock.with { self.delegate }
        guard let delegate else { return }

        pp_log(ctx, .os, .debug, "On better path")
        delegate.on_better_path(delegate.ctx)
    }

    func setTunnelSettings(with info: TunnelRemoteInfoWrapper) async throws {
        guard let provider else {
            logReleasedProvider()
            throw PartoutError(.releasedObject)
        }
        let profile = try info.profile.asProfile()
        let tunnelSettings = profile.networkSettingsWrapper(with: info, options: options)
        pp_log(ctx, .os, .info, "Commit tunnel settings: \(tunnelSettings)")
        try await provider.setTunnelNetworkSettings(tunnelSettings)
    }

    func configureSockets(with descriptors: [SocketDescriptor]) {
    }

    func reportSnapshot(_ snapshot: TunnelSnapshot) {
        if options.logsSnapshots {
            pp_log(ctx, .os, .debug, "Report tunnel snapshot: \(snapshot)")
        }
        // The runtime already handles the connection events
        // to keep the tunnel environment up to date
    }

    func clearTunnelSettings(withKillSwitch: Bool) async {
        do {
            pp_log(ctx, .os, .info, "Clear tunnel settings (kill switch = \(withKillSwitch))")
            try await provider?.clearTunnelSettings(withKillSwitch: withKillSwitch)
        } catch {
            pp_log(ctx, .os, .error, "Unable to clear tunnel settings: \(error)")
        }
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
            pp_log(ctx, .os, .fault, "Dispose tunnel with error: \(error)")
        } else {
            pp_log(ctx, .os, .notice, "Dispose tunnel")
        }
        provider.cancelTunnelWithError(error)
    }
}

private extension PartoutTunnelController {
    func logReleasedProvider() {
        pp_log(ctx, .os, .info, "NEPacketTunnelProvider released")
    }
}

private extension Profile {
    func networkSettingsWrapper(
        with infoWrapper: TunnelRemoteInfoWrapper?,
        options: TunnelControllerOptions
    ) -> NEPacketTunnelNetworkSettings {
        let info = infoWrapper.map {
            TunnelRemoteInfo(
                originalModuleId: $0.originalModuleId,
                address: $0.address,
                modules: $0.modules?.map(\.containedModule),
                requiresVirtualDevice: $0.requiresVirtualDevice
            )
        }
        return networkSettings(with: info, options: options)
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
                .assumingMemoryBound(to: pp_tun_ctrl_delegate.self)
                .pointee

            controller.delegateLock.with {
                controller.delegate = copied
            }
            controller.onReachable(controller.reachability.isReachable)
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
                if let code = PartoutError.Code(rawValue: rawCode) {
                    return PartoutError(code)
                }
                return PartoutError(.unhandled, rawCode)
            }
            controller.cancelTunnelConnection(with: error)
        }

        private static func controller(from ref: UnsafeMutableRawPointer?) -> PartoutTunnelController? {
            guard let ref else {
                pp_log_g(.os, .error, "NETunnelController C bridge received a nil reference")
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

// Exported for pp_tun_ctrl_fnt_current() in tun_darwin.c.
@c(pp_swift_tun_ctrl_set_delegate)
public func pp_swift_tun_ctrl_set_delegate(
    _ ref: UnsafeMutableRawPointer?,
    _ delegate: UnsafeRawPointer?
) {
    PartoutTunnelController.Bindings.setDelegate(ref, delegate: delegate)
}

@c(pp_swift_tun_ctrl_set_tunnel)
public func pp_swift_tun_ctrl_set_tunnel(
    _ ref: UnsafeMutableRawPointer?,
    _ uuid: UnsafePointer<CChar>?,
    _ infoJSON: UnsafePointer<CChar>?
) -> Bool {
    PartoutTunnelController.Bindings.setTunnel(ref, uuid: uuid, infoJSON: infoJSON)
}

@c(pp_swift_tun_ctrl_configure_sockets)
public func pp_swift_tun_ctrl_configure_sockets(
    _ ref: UnsafeMutableRawPointer?,
    _ reachability: UnsafeRawPointer?,
    _ descriptors: UnsafePointer<Int32>?,
    _ descriptorsCount: Int
) -> Bool {
    PartoutTunnelController.Bindings.configureSockets(
        ref,
        reachability: reachability,
        descriptors: descriptors,
        descriptorsCount: descriptorsCount
    )
}

@c(pp_swift_tun_ctrl_report_snapshot)
public func pp_swift_tun_ctrl_report_snapshot(
    _ ref: UnsafeMutableRawPointer?,
    _ snapshotJSON: UnsafePointer<CChar>?
) {
    PartoutTunnelController.Bindings.reportSnapshot(ref, snapshotJSON: snapshotJSON)
}

@c(pp_swift_tun_ctrl_clear_tunnel)
public func pp_swift_tun_ctrl_clear_tunnel(
    _ ref: UnsafeMutableRawPointer?,
    _ killSwitch: Bool
) {
    PartoutTunnelController.Bindings.clearTunnel(ref, killSwitch: killSwitch)
}

@c(pp_swift_tun_ctrl_cancel_tunnel)
public func pp_swift_tun_ctrl_cancel_tunnel(
    _ ref: UnsafeMutableRawPointer?,
    _ errorCode: UnsafePointer<CChar>?
) {
    PartoutTunnelController.Bindings.cancelTunnel(ref, errorCode: errorCode)
}

private extension PartoutTunnelController {
    func logBridgeError(_ message: String, _ error: Error) {
        pp_log(ctx, .os, .error, "\(message): \(error)")
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
#endif
