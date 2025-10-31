// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Network
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// An observer that publishes updates from a `NWPathMonitor`.
public final class NEObservablePath: ReachabilityObserver {
    private let ctx: PartoutLoggerContext

    private let monitor: NWPathMonitor

    private nonisolated let subject: CurrentValueStream<NWPath>

    public init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
        monitor = NWPathMonitor()
        subject = CurrentValueStream(monitor.currentPath)
    }

    public func startObserving() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            pp_log(ctx, .os, .info, "Path updated: \(path.debugDescription)")
            subject.send(path)
        }
        monitor.start(queue: .global())
    }
}

extension NEObservablePath {
    public var stream: AsyncStream<NWPath> {
        subject.subscribe()
    }

    public var isReachable: Bool {
        // XXX: WireGuard suggests including .requiresConnection
        subject.value.status == .satisfied
    }

    public var isReachableStream: AsyncStream<Bool> {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var previous: Bool?
                for await path in self.stream {
                    guard !Task.isCancelled else {
                        pp_log(self.ctx, .os, .debug, "Cancelled NEObservablePath.isReachableStream")
                        break
                    }
                    let reachable = path.status.isSatisfiable
                    // Strip dups, is this ideal?
                    guard reachable != previous else {
                        continue
                    }
                    continuation.yield(reachable)
                    previous = reachable
                }
                continuation.finish()
            }
        }
    }
}

private extension NWPath.Status {
    var isSatisfiable: Bool {
        switch self {
        case .requiresConnection, .satisfied:
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }
}
