// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

final class DataPathWrapper {
    struct Parameters {
        let cipher: OpenVPN.Cipher?

        let digest: OpenVPN.Digest?

        let compressionFraming: OpenVPN.CompressionFraming

        let compressionAlgorithm: OpenVPN.CompressionAlgorithm

        let peerId: UInt32?
    }

    let dataPath: DataPathProtocol

    init(dataPath: DataPathProtocol) {
        self.dataPath = dataPath
    }

    func encrypt(_ packets: [Data], key: UInt8) throws -> [Data] {
        try dataPath.encrypt(packets, key: key)
    }

    func decrypt(_ packets: [Data]) throws -> (packets: [Data], keepAlive: Bool) {
        try dataPath.decrypt(packets)
    }
}
