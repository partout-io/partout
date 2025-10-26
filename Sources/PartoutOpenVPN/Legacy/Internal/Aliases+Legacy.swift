// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_exported import _PartoutCryptoOpenSSL_ObjC
import Foundation
internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

typealias LegacyPacket = ControlPacket
typealias LegacyPacketCode = PacketCode
typealias LegacyPacketProtocol = PacketProtocol
typealias LegacyZD = ZeroingData

extension PRNGProtocol {
    func safeLegacyData(length: Int) -> LegacyZD {
        precondition(length > 0)
        let randomBytes = pp_alloc_crypto(length)
        defer {
            bzero(randomBytes, length)
            free(randomBytes)
        }
        guard SecRandomCopyBytes(kSecRandomDefault, length, randomBytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        return Z(Data(bytes: randomBytes, count: length))
    }
}

extension LegacyZD: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? "[\(length) bytes, \(toHex())]" : "[\(length) bytes]"
    }
}

func Z() -> LegacyZD {
    LegacyZD(length: 0)
}

func Z(length: Int) -> LegacyZD {
    LegacyZD(length: length)
}

func Z(bytes: UnsafePointer<UInt8>, length: Int) -> LegacyZD {
    LegacyZD(bytes: bytes, length: length)
}

func Z(_ uint8: UInt8) -> LegacyZD {
    LegacyZD(uInt8: uint8)
}

func Z(_ uint16: UInt16) -> LegacyZD {
    LegacyZD(uInt16: uint16)
}

func Z(_ data: Data) -> LegacyZD {
    LegacyZD(data: data)
}

func Z(_ data: Data, _ offset: Int, _ length: Int) -> LegacyZD {
    LegacyZD(data: data, offset: offset, length: length)
}

func Z(_ string: String, nullTerminated: Bool) -> LegacyZD {
    LegacyZD(string: string, nullTerminated: nullTerminated)
}

extension SecureData {
    var legacyZData: LegacyZD {
        Z(toData())
    }
}

extension LegacyPacketProtocol {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packetId < rhs.packetId
    }
}
