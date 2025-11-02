// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Task where Success == Never, Failure == Never {
    public static func sleep(milliseconds: Int) async throws {
        try await Self.sleep(nanoseconds: UInt64(milliseconds) * NSEC_PER_MSEC)
    }

    public static func sleep(interval: Double) async throws {
        try await Self.sleep(nanoseconds: UInt64(interval * Double(NSEC_PER_SEC)))
    }
}
