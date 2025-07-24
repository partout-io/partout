//
//  PlatformPRNG.swift
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

import _PartoutCryptoCore
import _PartoutCryptoCore_C
import _PartoutVendorsPortable_C
import Foundation
import PartoutCore

/// Implementation of ``/PartoutCore/PRNGProtocol`` with the OS C library.
public final class PlatformPRNG: PRNGProtocol {
    public init() {
    }

    public func uint32() -> UInt32 {
        fatalError("Not supported")
    }

    public func data(length: Int) -> Data {
        precondition(length > 0)
        let randomData = zd_create(length)
        guard prng_do(randomData.pointee.bytes, length) else {
            fatalError("prng_do() failed")
        }
        return Data(zeroing: randomData)
    }
}
