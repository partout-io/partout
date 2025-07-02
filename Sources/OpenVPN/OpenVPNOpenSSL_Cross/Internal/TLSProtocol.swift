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

protocol TLSProtocol {
    func start() throws

    func isConnected() -> Bool

    func putPlainText(_ text: String) throws

    func putRawPlainText(_ text: Data) throws

    func putCipherText(_ data: Data) throws

    func pullPlainText() throws -> Data

    func pullCipherText() throws -> Data

    func caMD5() throws -> String
}
