// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public protocol SocketIOInterface: IOInterface {
    func shutdown() async
}
