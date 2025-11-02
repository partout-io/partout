// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

protocol ControlChannelSerializer {
    func reset()

    func serialize(packet: CrossPacket) throws -> Data

    func deserialize(data: Data, start: Int, end: Int?) throws -> CrossPacket
}
