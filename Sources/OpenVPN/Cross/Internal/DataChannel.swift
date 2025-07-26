// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

final class DataChannel {
    private let ctx: PartoutLoggerContext

    let key: UInt8

    private let dataPath: DataPathProtocol

    init(_ ctx: PartoutLoggerContext, key: UInt8, dataPath: DataPathProtocol) {
        self.ctx = ctx
        self.key = key
        self.dataPath = dataPath
    }

    func encrypt(packets: [Data]) throws -> [Data]? {
        try dataPath.encrypt(packets, key: key)
    }

    func decrypt(packets: [Data]) throws -> [Data]? {
        let result = try dataPath.decrypt(packets)
        if result.keepAlive {
            pp_log(ctx, .openvpn, .debug, "Data: Received ping, do nothing")
        }
        return result.packets
    }
}
