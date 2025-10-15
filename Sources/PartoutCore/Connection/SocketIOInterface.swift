// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// An ``IOInterface`` suitable for representing a socket.
public protocol SocketIOInterface: IOInterface {
    func shutdown() async
}
