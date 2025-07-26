//
//  NEObservablePath.swift
//  Partout
//
//  Created by Davide De Rosa on 3/30/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import Network
import PartoutCore

/// A ``/PartoutCore/ReachabilityObserver`` that publishes updates from a `NWPathMonitor`.
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
            pp_log(ctx, .ne, .debug, "Path updated: \(path.debugDescription)")
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
                for await path in stream {
                    guard !Task.isCancelled else {
                        pp_log(ctx, .ne, .debug, "Cancelled NEObservablePath.isReachableStream")
                        break
                    }
                    let reachable = path.status == .satisfied
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
