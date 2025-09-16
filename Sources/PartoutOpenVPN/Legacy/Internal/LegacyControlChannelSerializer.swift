// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

protocol LegacyControlChannelSerializer {
    func reset()

    func serialize(packet: LegacyPacket) throws -> Data

    func deserialize(data: Data, start: Int, end: Int?) throws -> LegacyPacket
}
