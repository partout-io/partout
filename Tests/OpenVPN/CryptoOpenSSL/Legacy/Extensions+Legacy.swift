//
//  Extensions+Legacy.swift
//  Partout
//
//  Created by Davide De Rosa on 6/18/25.
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

extension CryptoFlagsWrapper {
    init(objcFlags: CryptoFlags) {
        iv = objcFlags.iv
        ivLength = objcFlags.ivLength
        ad = objcFlags.ad
        adLength = objcFlags.adLength
        forTesting = objcFlags.forTesting.boolValue
    }

    var objcFlags: CryptoFlags {
        var flags = CryptoFlags()
        flags.iv = iv
        flags.ivLength = ivLength
        flags.ad = ad
        flags.adLength = adLength
        flags.forTesting = ObjCBool(forTesting)
        return flags
    }
}

extension Encrypter {
    func encryptData(_ data: Data, flags: CryptoFlagsWrapper?) throws -> Data {
        var objcFlags = CryptoFlags()
        let ptr = flags.pointer(to: &objcFlags)
        return try encryptData(data, flags: ptr)
    }
}

extension Decrypter {
    func decryptData(_ data: Data, flags: CryptoFlagsWrapper?) throws -> Data {
        var objcFlags = CryptoFlags()
        let ptr = flags.pointer(to: &objcFlags)
        return try decryptData(data, flags: ptr)
    }

    func verifyData(_ data: Data, flags: CryptoFlagsWrapper?) throws {
        var objcFlags = CryptoFlags()
        let ptr = flags.pointer(to: &objcFlags)
        try verifyData(data, flags: ptr)
    }
}

extension Optional where Wrapped == CryptoFlagsWrapper {
    func pointer(to objcFlags: UnsafeMutablePointer<CryptoFlags>) -> UnsafeMutablePointer<CryptoFlags>? {
        map {
            objcFlags.pointee = $0.objcFlags
            return objcFlags
        }
    }
}
