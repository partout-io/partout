// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

protocol ControlChannelSerializer {
    func reset()

    func serialize(packet: CControlPacket) throws -> Data

    func deserialize(data: Data, start: Int, end: Int?) throws -> CControlPacket
}
