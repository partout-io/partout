//
//  DataPathWrapper+Legacy.swift
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

import _PartoutOpenVPN
internal import _PartoutOpenVPNOpenSSL_ObjC

extension DataPathWrapper {
    static func legacy(with parameters: Parameters) -> DataPathWrapper {
        fatalError("FIXME: ###")
    }
}

extension DataPath: DataPathProtocol, DataPathLegacyProtocol {
    func encrypt(_ packets: [Data], key: UInt8) throws -> [Data] {
        try encryptPackets(packets, key: key)
    }

    func decrypt(_ packets: [Data]) throws -> (packets: [Data], keepAlive: Bool) {
        var keepAlive = false
        let packets = try decryptPackets(packets, keepAlive: &keepAlive)
        return (packets, keepAlive)
    }
}

extension DataPath: DataPathTestingProtocol {

    // MARK: DataPathEncrypter

    func assemble(packetId: UInt32, payload: Data) -> Data {
        fatalError("FIXME: ###")
    }

    func encrypt(key: UInt8, packetId: UInt32, assembled: Data) throws -> Data {
        fatalError("FIXME: ###")
    }

    func assembleAndEncrypt(_ packet: Data, key: UInt8, packetId: UInt32) throws -> Data {
        fatalError("FIXME: ###")
    }

    // MARK: DataPathDecrypter

    func decrypt(packet: Data) throws -> DataPathDecryptedTuple {
        fatalError("FIXME: ###")
    }

    func parse(decrypted: Data, header: inout UInt8) throws -> Data {
        fatalError("FIXME: ###")
    }

    func decryptAndParse(_ packet: Data) throws -> DataPathDecryptedAndParsedTuple {
        fatalError("FIXME: ###")
    }
}
