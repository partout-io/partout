// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutOpenVPN
#endif

final class DataPathWrapper {
    struct Parameters {
        let cipher: OpenVPN.Cipher?

        let digest: OpenVPN.Digest?

        let compressionFraming: OpenVPN.CompressionFraming

        let peerId: UInt32?
    }

    let dataPath: DataPathTestingProtocol

    init(dataPath: DataPathTestingProtocol) {
        self.dataPath = dataPath
    }

    func encrypt(_ packets: [Data], key: UInt8) throws -> [Data] {
        try dataPath.encrypt(packets, key: key)
    }

    func decrypt(_ packets: [Data]) throws -> (packets: [Data], keepAlive: Bool) {
        try dataPath.decrypt(packets)
    }
}
