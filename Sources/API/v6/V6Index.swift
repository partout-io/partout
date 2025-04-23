//
//  V6Index.swift
//  Partout
//
//  Created by Davide De Rosa on 11/24/19.
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
import GenericJSON
import PartoutCore
import PartoutProviders

extension API.V6 {
    public struct Index: Decodable {
        public struct Provider: Decodable {
            public let id: ProviderID

            public let description: String

            public let metadata: [String: JSON]
        }

        public let providers: [Provider]
    }
}
