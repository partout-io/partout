// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Represents an I/O interface able to read and write data.
public protocol IOInterface: AnyObject, Sendable {
    /// The file descriptor, if available.
    var fileDescriptor: FileDescriptor? { get }

    /// Reads packets from the interface.
    func readPackets() async throws -> [Data]

    /// Writes packets to the interface.
    ///
    /// - Parameter packets: The packets to write.
    func writePackets(_ packets: [Data]) async throws
}

extension IOInterface {
    public var fileDescriptor: FileDescriptor? {
        nil
    }
}
