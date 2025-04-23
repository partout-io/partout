//
//  ProviderHeuristic.swift
//  Partout
//
//  Created by Davide De Rosa on 3/5/25.
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

public enum ProviderHeuristic: Identifiable, Hashable, Codable, Sendable {
    case exact(ProviderServer)

    case sameCountry(String)

    case sameRegion(ProviderRegion)

    public var id: String {
        switch self {
        case .exact(let server):
            return "server.\(server.serverId)"
        case .sameCountry(let code):
            return "country.\(code)"
        case .sameRegion(let region):
            return "region.\(region.id)"
        }
    }
}

extension ProviderHeuristic {
    public func matches(_ server: ProviderServer) -> Bool {
        switch self {
        case .exact(let heuristicServer):
            return server.serverId == heuristicServer.serverId
        case .sameCountry(let code):
            return server.metadata.countryCode == code
        case .sameRegion(let region):
            return server.regionId == region.id
        }
    }
}
