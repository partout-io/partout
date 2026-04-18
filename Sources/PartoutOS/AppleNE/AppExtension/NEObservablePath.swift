// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Dispatch
import Network

/// An observer that publishes updates from a `NWPathMonitor`.
public final class NEObservablePath: ReachabilityObserver {
    private let ctx: PartoutLoggerContext

    private let monitor: NWPathMonitor

    private let monitorQueue: DispatchQueue

    private nonisolated let subject: CurrentValueStream<NWPath>

    nonisolated(unsafe)
    private var wasSatisfiable: Bool?

    public init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
        monitor = NWPathMonitor()
        monitorQueue = DispatchQueue(label: "NEObservablePath")
        subject = CurrentValueStream(monitor.currentPath)
    }

    public func startObserving() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let didChangeSatisfiability = path.isSatisfiable != self.wasSatisfiable
            let level: DebugLog.Level = didChangeSatisfiability ? .info : .debug
            pp_log(self.ctx, .os, level, "Path updated: \(path.debugDescription)")
            self.wasSatisfiable = path.isSatisfiable
            self.subject.send(path)
        }
        monitor.start(queue: monitorQueue)
    }

    public func stopObserving() {
    }
}

extension NEObservablePath {
    public var stream: AsyncStream<NWPath> {
        subject.subscribe()
    }

    public var isReachable: Bool {
        subject.value.isSatisfiable
    }

    public var isReachableStream: AsyncStream<Bool> {
        AsyncStream { [weak self] continuation in
            let relayTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let pathStream = self.stream
                for await path in pathStream {
                    guard !Task.isCancelled else {
                        pp_log(self.ctx, .os, .debug, "Cancelled NEObservablePath.isReachableStream")
                        break
                    }
                    let reachable = path.isSatisfiable
                    continuation.yield(reachable)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                relayTask.cancel()
            }
        }
    }
}

private extension NWPath {
    var isSatisfiable: Bool {
        switch status {
        case .requiresConnection, .satisfied:
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }
}
