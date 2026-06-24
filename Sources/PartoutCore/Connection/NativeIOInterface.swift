// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Provides an abstraction for the I/O of a native device.
public protocol NativeIOInterface: Sendable {
    func setEventMask(read: Bool, write: Bool) throws
    func resetEvents() throws
    func read(_ buf: inout [UInt8]) throws -> Int?
    func write(_ data: Data, offset: Int) throws -> Int
    func cleanup()
    var lastErrorCode: Int32 { get }
}

/// Errors thrown by ``NativeIOInterface``.
public enum NativeIOError: Error, CustomDebugStringConvertible {
    case wouldBlock(Side)
    case backpressure(Side)
    case eof(Side)
    case libc(Side, Int32)

    var side: Side {
        switch self {
        case .wouldBlock(let side): side
        case .backpressure(let side): side
        case .eof(let side): side
        case .libc(let side, _): side
        }
    }

    public var debugDescription: String {
        switch self {
        case .wouldBlock(let side): "\(side): would block"
        case .backpressure(let side): "\(side): backpressure"
        case .eof(let side): "\(side): EOF"
        case .libc(let side, let code): "\(side): last_error=\(code)"
        }
    }
}
