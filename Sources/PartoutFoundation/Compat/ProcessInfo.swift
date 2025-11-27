// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public final class ProcessInfo {
    public struct OperatingSystemVersion {
        public let majorVersion: Int
        public let minorVersion: Int
        public let patchVersion: Int
    }

    public static let processInfo = ProcessInfo()

    public var operatingSystemVersion: OperatingSystemVersion {
        fatalError()
    }
}
