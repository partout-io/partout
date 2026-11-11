// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import Network

/// A continuous stream of network events.
final class NetworkMonitor: @unchecked Sendable {
    enum Event: Sendable {
        case reachability(Bool)

        case betterPath
    }

    private let monitor: NWPathMonitor

    private let monitorQueue: DispatchQueue

    private let subject: PassthroughStream<Event>

    private let reachabilityLock: SemaphoreMutex

    private var currentReachability: Bool

    private var previousPathPreference: NetworkPathPreference?

    init() {
        monitor = NWPathMonitor()
        monitorQueue = DispatchQueue(label: "NetworkMonitor")
        subject = PassthroughStream()
        reachabilityLock = SemaphoreMutex()
        currentReachability = monitor.currentPath.isSatisfiable
    }

    deinit {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        subject.finish()
    }

    var events: AsyncStream<Event> {
        subject.subscribe()
    }

    var isReachable: Bool {
        reachabilityLock.with {
            currentReachability
        }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: monitorQueue)
    }
}

private extension NetworkMonitor {
    func handle(_ path: NWPath) {
        let isReachable = path.isSatisfiable
        reachabilityLock.with {
            currentReachability = isReachable
        }
        subject.send(.reachability(isReachable))

        let nextPathPreference = NetworkPathPreference(path)
        defer {
            previousPathPreference = nextPathPreference
        }
        guard let previousPathPreference else {
            return
        }
        guard nextPathPreference > previousPathPreference else {
            return
        }

        subject.send(.betterPath)
    }
}

private struct NetworkPathPreference: Comparable, Sendable {
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

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.statusScore != rhs.statusScore {
            return lhs.statusScore < rhs.statusScore
        }
        if lhs.isUnconstrained != rhs.isUnconstrained {
            return !lhs.isUnconstrained && rhs.isUnconstrained
        }
        if lhs.isInexpensive != rhs.isInexpensive {
            return !lhs.isInexpensive && rhs.isInexpensive
        }
        return lhs.interfaceScore < rhs.interfaceScore
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
