//
//  Extensions.swift
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

import Foundation

extension Data {
    init(hex: String) {
        assert(hex.count & 1 == 0)
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                break
            }
            index = nextIndex
        }
        self.init(data)
    }

    func toHex() -> String {
        var hexString = ""
        for i in 0..<count {
            hexString += String(format: "%02x", self[i])
        }
        return hexString
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
