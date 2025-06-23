//
//  ZeroingData+Extensions.swift
//  Partout
//
//  Created by Davide De Rosa on 1/14/25.
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

internal import _PartoutCryptoOpenSSL_ObjC
import Foundation
<<<<<<<< HEAD:Cross/OpenVPNCross/Sources/OpenVPN/OpenVPNOpenSSL/Legacy/ZeroingData+Extensions.swift
import PartoutCore
========
import XCTest
>>>>>>>> master:Tests/OpenVPN/CryptoOpenSSL/Extensions.swift

extension SecureData {
    var zData: ZeroingData {
        Z(toData())
    }
}

extension ZeroingData: @retroactive SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? "[\(length) bytes, \(toHex())]" : "[\(length) bytes]"
    }
}

extension UnsafeRawBufferPointer {
    var bytePointer: UnsafePointer<Element> {
        guard let address = bindMemory(to: Element.self).baseAddress else {
            fatalError("Cannot bind to self")
        }
        return address
    }
}

protocol CryptoFlagsProviding {
    var packetId: [UInt8] { get }

    var ad: [UInt8] { get }
}

extension CryptoFlagsProviding {
    func newCryptoFlags() -> CryptoFlagsWrapper {
        packetId.withUnsafeBufferPointer { iv in
            ad.withUnsafeBufferPointer { ad in
                CryptoFlagsWrapper(
                    iv: iv.baseAddress,
                    ivLength: iv.count,
                    ad: ad.baseAddress,
                    adLength: ad.count,
                    forTesting: true
                )
            }
        }
    }
}
