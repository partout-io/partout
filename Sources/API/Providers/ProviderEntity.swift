//
//  ProviderEntity.swift
//  Partout
//
//  Created by Davide De Rosa on 10/9/24.
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

public struct ProviderEntity: Hashable, Codable, Sendable {
    public struct Header: Hashable, Codable, Sendable {
        public let providerId: ProviderID

        public let id: String

        public let countryCode: String
    }

    public let server: ProviderServer

    public let preset: ProviderPreset

    public let heuristic: ProviderHeuristic?

    public init(server: ProviderServer, preset: ProviderPreset, heuristic: ProviderHeuristic?) {
        self.server = server
        self.preset = preset
        self.heuristic = heuristic
    }

    public var header: Header {
        Header(
            providerId: server.metadata.providerId,
            id: server.id,
            countryCode: server.metadata.countryCode
        )
    }
}
