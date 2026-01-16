// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

enum OCCPacket: UInt8 {
    case exit = 0x06

    private static let magicString = Data(hex: "287f346bd4ef7a812d56b8d3afc5459c")

    func serialized(_ info: Any? = nil) -> Data {
        var data = OCCPacket.magicString
        data.append(rawValue)
        switch self {
        case .exit:
            break // nothing more
        }
        return data
    }
}
