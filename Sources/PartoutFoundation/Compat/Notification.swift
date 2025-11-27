// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public final class NotificationCenter {
    private init() {
    }

    public static let `default` = NotificationCenter()

    public func removeObserver(_ observer: Any) {
        fatalError()
    }
}

public final class Notification {
    public struct Name {
        public init(_ string: String) {
            fatalError()
        }
    }
}
