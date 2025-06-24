//
//  DataChannel.swift
//  Partout
//
//  Created by Davide De Rosa on 5/2/24.
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
import PartoutCore

final class DataChannel {
    private let ctx: PartoutLoggerContext

    let key: UInt8

    private let dataPath: DataPathProtocol

    init(_ ctx: PartoutLoggerContext, key: UInt8, dataPath: DataPathProtocol) {
        self.ctx = ctx
        self.key = key
        self.dataPath = dataPath
    }

    func encrypt(packets: [Data]) throws -> [Data]? {
        try dataPath.encrypt(packets, key: key)
    }

    func decrypt(packets: [Data]) throws -> [Data]? {
        let result = try dataPath.decrypt(packets)
        if result.keepAlive {
            pp_log(ctx, .openvpn, .debug, "Data: Received ping, do nothing")
        }
        return result.packets
    }
}
