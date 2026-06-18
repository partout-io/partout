// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct DataPathDecryptedTuple {
    let packetId: UInt32

    let data: Data

    init(_ packetId: UInt32, _ data: Data) {
        self.packetId = packetId
        self.data = data
    }
}

struct DataPathDecryptedAndParsedTuple {
    let packetId: UInt32

    let header: UInt8

    let isKeepAlive: Bool

    let data: Data

    init(_ packetId: UInt32, _ header: UInt8, _ isKeepAlive: Bool, _ data: Data) {
        self.packetId = packetId
        self.header = header
        self.isKeepAlive = isKeepAlive
        self.data = data
    }
}

// new C-based protocol
protocol DataPathProtocol {
    func encrypt(_ packets: [Data], key: UInt8) throws -> [Data]

    func decrypt(_ packets: [Data]) throws -> (packets: [Data], keepAlive: Bool)
}

protocol DataPathTestingProtocol: DataPathProtocol {
    func assemble(packetId: UInt32, payload: Data) -> Data

    func encrypt(key: UInt8, packetId: UInt32, assembled: Data) throws -> Data

    func assembleAndEncrypt(_ packet: Data, key: UInt8, packetId: UInt32) throws -> Data

    func decrypt(packet: Data) throws -> DataPathDecryptedTuple

    func parse(decrypted: Data, header: inout UInt8) throws -> Data

    func decryptAndParse(_ packet: Data) throws -> DataPathDecryptedAndParsedTuple
}
