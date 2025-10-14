// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Represents an I/O interface able to read and write data.
public protocol IOInterface: AnyObject, Sendable {

    /// The file descriptor, if available.
    var fileDescriptor: UInt64? { get }

    /// Reads packets from the interface.
    func readPackets() async throws -> [Data]

    /// Writes packets to the interface.
    ///
    /// - Parameter packets: The packets to write.
    func writePackets(_ packets: [Data]) async throws
}
