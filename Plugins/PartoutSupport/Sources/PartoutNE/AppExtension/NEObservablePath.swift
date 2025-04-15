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

import Combine
import Foundation
import Network
import PartoutCore

/// Publishes updates from a `NWPathMonitor`.
public final class NEObservablePath: ReachabilityObserver {
    private let monitor: NWPathMonitor

    private nonisolated let subject: CurrentValueSubject<NWPath, Never>

    public init() {
        monitor = NWPathMonitor()
        subject = CurrentValueSubject(monitor.currentPath)
    }

    public func startObserving() {
        monitor.pathUpdateHandler = { [weak self] path in
            pp_log(.ne, .debug, "Path updated: \(path.debugDescription)")
            self?.subject.send(path)
        }
        monitor.start(queue: .global())
    }
}

extension NEObservablePath {
    public var publisher: AnyPublisher<NWPath, Never> {
        subject.eraseToAnyPublisher()
    }

    public var isReachable: Bool {
        subject.value.status == .satisfied
    }

    public var isReachablePublisher: AnyPublisher<Bool, Never> {
        publisher
            .map {
                $0.status == .satisfied
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
