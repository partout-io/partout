// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import Network

/// A ``BetterPathBlock`` implementation backed by `NWPathMonitor`.
public struct NWPathMonitorBetterPathBlock: Sendable {
    private let ctx: PartoutLoggerContext

    public init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
    }

    public var block: BetterPathBlock {
        { [ctx] in
            NWPathMonitorBetterPathStream(ctx).stream
        }
    }
}

private final class NWPathMonitorBetterPathStream: @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let monitor: NWPathMonitor

    private let monitorQueue: DispatchQueue

    fileprivate let stream: PassthroughStream<Void>

    private var previousPath: NWPathPreference?

    private var didSignal: Bool

    private var didStop: Bool

    init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
        monitor = NWPathMonitor()
        monitorQueue = DispatchQueue(label: "NWPathMonitorBetterPathBlock")
        stream = PassthroughStream()
        didSignal = false
        didStop = false

        monitor.pathUpdateHandler = { [self] path in
            handle(path)
        }
        monitor.start(queue: monitorQueue)

        Task { [self] in
            for await _ in stream.subscribe() {
                // Keep the monitor alive until the socket finishes the stream.
            }
            stop()
        }
    }
}

private extension NWPathMonitorBetterPathStream {
    func handle(_ path: NWPath) {
        guard !didSignal, !didStop else {
            return
        }

        let nextPath = NWPathPreference(path)
        defer {
            previousPath = nextPath
        }

        guard let previousPath else {
            return
        }
        guard nextPath.isBetter(than: previousPath) else {
            return
        }

        didSignal = true
        pp_log(ctx, .os, .notice, "Better network path detected, reconnect socket")
        stream.send()
        stopOnMonitorQueue()
    }

    func stop() {
        monitorQueue.async { [self] in
            stopOnMonitorQueue()
        }
    }

    func stopOnMonitorQueue() {
        guard !didStop else {
            return
        }
        didStop = true
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

private struct NWPathPreference: Sendable {
    private let statusScore: Int

    private let isUnconstrained: Bool

    private let isInexpensive: Bool

    private let interfaceScore: Int

    init(_ path: NWPath) {
        statusScore = path.status.preferenceScore
        isUnconstrained = !path.isConstrained
        isInexpensive = !path.isExpensive
        interfaceScore = path.interfacePreferenceScore
    }

    func isBetter(than other: Self) -> Bool {
        if statusScore != other.statusScore {
            return statusScore > other.statusScore
        }
        if isUnconstrained != other.isUnconstrained {
            return isUnconstrained && !other.isUnconstrained
        }
        if isInexpensive != other.isInexpensive {
            return isInexpensive && !other.isInexpensive
        }
        return interfaceScore > other.interfaceScore
    }
}

private extension NWPath {
    var interfacePreferenceScore: Int {
        if usesInterfaceType(.wiredEthernet) {
            return 5
        }
        if usesInterfaceType(.wifi) {
            return 4
        }
        if usesInterfaceType(.cellular) {
            return 3
        }
        if usesInterfaceType(.other) {
            return 2
        }
        if usesInterfaceType(.loopback) {
            return 1
        }
        return 0
    }
}

private extension NWPath.Status {
    var preferenceScore: Int {
        switch self {
        case .satisfied:
            return 2
        case .requiresConnection:
            return 1
        case .unsatisfied:
            return 0
        @unknown default:
            return 1
        }
    }
}
