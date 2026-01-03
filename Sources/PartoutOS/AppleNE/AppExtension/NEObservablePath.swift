// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Network

/// An observer that publishes updates from a `NWPathMonitor`.
public final class NEObservablePath: ReachabilityObserver {
    private let ctx: PartoutLoggerContext

    private let monitor: NWPathMonitor

    private nonisolated let subject: CurrentValueStream<UniqueID, NWPath>

    public init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
        monitor = NWPathMonitor()
        subject = CurrentValueStream(monitor.currentPath)
    }

    public func startObserving() {
        var wasSatifiable: Bool?
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let didChangeSatisfiability = path.isSatisfiable != wasSatifiable
            let level: DebugLog.Level = didChangeSatisfiability ? .info : .debug
            pp_log(ctx, .os, level, "Path updated: \(path.debugDescription)")
            wasSatifiable = path.isSatisfiable
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
        subject.value.isSatisfiable
    }

    public var isReachableStream: AsyncStream<Bool> {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                for await path in self.stream {
                    guard !Task.isCancelled else {
                        pp_log(self.ctx, .os, .debug, "Cancelled NEObservablePath.isReachableStream")
                        break
                    }
                    let reachable = path.isSatisfiable
                    continuation.yield(reachable)
                }
                continuation.finish()
            }
        }
    }
}

private extension NWPath {
    var isSatisfiable: Bool {
        let target: [NWInterface.InterfaceType] = [
            .cellular, .wifi, .wiredEthernet
        ]
        let isAvailable = target.contains {
            usesInterfaceType($0)
        }
        guard isAvailable else { return false }
        return status == .satisfied
    }
}
