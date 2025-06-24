//
//  TLSProtocol.swift
//  Partout
//
//  Created by Davide De Rosa on 6/24/25.
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
import Foundation

// FIXME: ###, beware of optionals in Negotiator, confusion between caught/ignored errors
protocol TLSProtocol {
    func start() throws

    func putPlainText(_ text: String) throws

    func putRawPlainText(_ text: CZeroingData) throws -> Int

    func putCipherText(_ data: Data) throws

    func pullCipherText() throws -> Data?

    // cipher text is then "put into" a network socket

    func isConnected() -> Bool
}
