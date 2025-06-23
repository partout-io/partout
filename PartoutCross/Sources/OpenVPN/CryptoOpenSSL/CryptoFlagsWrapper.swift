//
//  CryptoFlagsWrapper.swift
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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

struct CryptoFlagsWrapper {
    let iv: UnsafePointer<UInt8>?

    let ivLength: Int

    let ad: UnsafePointer<UInt8>?

    let adLength: Int

    let forTesting: Bool

    init(
        iv: UnsafePointer<UInt8>? = nil,
        ivLength: Int = .zero,
        ad: UnsafePointer<UInt8>? = nil,
        adLength: Int = .zero,
        forTesting: Bool
    ) {
        self.iv = iv
        self.ivLength = ivLength
        self.ad = ad
        self.adLength = adLength
        self.forTesting = forTesting
    }
}
