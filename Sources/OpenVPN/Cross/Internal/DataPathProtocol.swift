//
//  DataPathProtocol.swift
//  Partout
//
//  Created by Davide De Rosa on 6/20/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation

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

// old ObjC protocol
protocol DataPathLegacyProtocol {
    func encryptPackets(_ packets: [Data], key: UInt8) throws -> [Data]

    func decryptPackets(_ packets: [Data], keepAlive: UnsafeMutablePointer<Bool>?) throws -> [Data]
}

protocol DataPathTestingProtocol: DataPathProtocol {
    func assemble(packetId: UInt32, payload: Data) -> Data

    func encrypt(key: UInt8, packetId: UInt32, assembled: Data) throws -> Data

    func assembleAndEncrypt(_ packet: Data, key: UInt8, packetId: UInt32) throws -> Data

    func decrypt(packet: Data) throws -> DataPathDecryptedTuple

    func parse(decrypted: Data, header: inout UInt8) throws -> Data

    func decryptAndParse(_ packet: Data) throws -> DataPathDecryptedAndParsedTuple
}
