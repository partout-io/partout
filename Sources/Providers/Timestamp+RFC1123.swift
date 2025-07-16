//
//  Timestamp+RFC1123.swift
//  Partout
//
//  Created by Davide De Rosa on 3/29/25.
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

private let rfc1123: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(abbreviation: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    return formatter
}()

extension Timestamp {
    public func toRFC1123() -> String {
        rfc1123
            .string(from: date)
    }
}

extension String {
    public func fromRFC1123() -> Timestamp? {
        rfc1123
            .date(from: self)
            .map(\.timestamp)
    }
}
