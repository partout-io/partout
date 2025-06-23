//
//  PRNGProtocol+Extensions.swift
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

internal import _PartoutCryptoOpenSSL_Cross
internal import _PartoutOpenVPNOpenSSL_C
import Foundation
import PartoutCore

extension PRNGProtocol {
    func safeData(length: Int) -> CZeroingData {
        precondition(length > 0)
        let randomData = CZ(length: length)
        guard prng_do(randomData.mutableBytes, length) else {
            fatalError("random_do() failed")
        }
        return randomData
    }
}
