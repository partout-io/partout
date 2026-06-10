// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Represents an I/O interface able to read and write data.
public protocol IOInterface: AnyObject, Sendable {
    /// The file descriptor, if available.
    var muxDescriptor: FileDescriptor? { get }

    /// Reads packets from the interface.
    @available(*, deprecated, message: "Use FdLooper")
    func readPackets() async throws -> [Data]

    /// Writes packets to the interface.
    ///
    /// - Parameter packets: The packets to write.
    @available(*, deprecated, message: "Use FdLooper")
    func writePackets(_ packets: [Data]) async throws
}

extension IOInterface {
    public var muxDescriptor: FileDescriptor? {
        nil
    }
}
