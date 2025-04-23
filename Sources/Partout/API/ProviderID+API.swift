//
//  ProviderID+Support.swift
//  Partout
//
//  Created by Davide De Rosa on 10/7/24.
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

#if canImport(PartoutAPI)

import Foundation
import PartoutCore
import PartoutProviders

extension ProviderID {
    public static let hideme = Self(rawValue: "hideme")

    public static let ivpn = Self(rawValue: "ivpn")

    public static let mullvad = Self(rawValue: "mullvad")

    public static let nordvpn = Self(rawValue: "nordvpn")

    public static let oeck = Self(rawValue: "oeck")

    public static let pia = Self(rawValue: "pia")

    public static let protonvpn = Self(rawValue: "protonvpn")

    public static let surfshark = Self(rawValue: "surfshark")

    public static let torguard = Self(rawValue: "torguard")

    public static let tunnelbear = Self(rawValue: "tunnelbear")

    public static let vyprvpn = Self(rawValue: "vyprvpn")

    public static let windscribe = Self(rawValue: "windscribe")
}

#endif
