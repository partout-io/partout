// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Provides an abstraction for the I/O of a native device.
public protocol NativeIOInterface: Sendable {
    func resetEvents() throws
    func read(_ buf: inout [UInt8]) -> Int32
    func write(_ data: Data, offset: Int) -> Int32
    func cleanup()
    var lastErrorCode: Int32 { get }
}
