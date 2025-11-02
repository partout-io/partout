// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

final class LegacyDataChannel {
    private let ctx: PartoutLoggerContext

    let key: UInt8

    private let dataPath: DataPath

    init(_ ctx: PartoutLoggerContext, key: UInt8, dataPath: DataPath) {
        self.ctx = ctx
        self.key = key
        self.dataPath = dataPath
    }

    func encrypt(packets: [Data]) throws -> [Data]? {
        try dataPath.encryptPackets(packets, key: key)
    }

    func decrypt(packets: [Data]) throws -> [Data]? {
        var keepAlive = false
        let decrypted = try dataPath.decryptPackets(packets, keepAlive: &keepAlive)
        if keepAlive {
            pp_log(ctx, .openvpn, .debug, "Data: Received ping, do nothing")
        }
        return decrypted
    }
}
