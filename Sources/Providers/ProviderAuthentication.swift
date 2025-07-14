//
//  ProviderToken.swift
//  Partout
//
//  Created by Davide De Rosa on 7/12/25.
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

// treat as a "C union"
public struct ProviderAuthentication: Hashable, Codable, Sendable {
    public struct Credentials: Hashable, Codable, Sendable {
        public var username: String

        public var password: String

        public init(username: String = "", password: String = "") {
            self.username = username
            self.password = password
        }
    }

    public struct Token: Hashable, Codable, Sendable {
        public let accessToken: String

        public let expiryDate: Date

        public init(accessToken: String, expiryDate: Date) {
            self.accessToken = accessToken
            self.expiryDate = expiryDate
        }
    }

    public var credentials: Credentials?

    public var token: Token?

    public init() {
    }

    public var isEmpty: Bool {
        credentials == nil && token == nil
    }
}
