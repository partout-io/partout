//
//  Partout.swift
//  Partout
//
//  Created by Davide De Rosa on 3/29/24.
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

// MARK: Core

@_exported import PartoutCore

// MARK: - Platforms

#if canImport(_PartoutPlatformAndroid)
@_exported import _PartoutPlatformAndroid
#endif

#if canImport(_PartoutPlatformApple)
@_exported import _PartoutPlatformApple
#endif

#if canImport(_PartoutPlatformAppleNE)
@_exported import _PartoutPlatformAppleNE
#endif

#if canImport(_PartoutPlatformWindows)
@_exported import _PartoutPlatformWindows
#endif

// MARK: - Providers

@_exported import PartoutProviders

extension PartoutError.Code.Providers {

    /// A provider module is corrupt.
    public static let corruptProviderModule = PartoutError.Code("corruptProviderModule")
}

// MARK: - API

#if canImport(PartoutAPI)
@_exported import PartoutAPI
#endif

// MARK: - Modules

#if canImport(_PartoutOpenVPN)
@_exported import _PartoutOpenVPN
#endif
#if canImport(_PartoutWireGuard)
@_exported import _PartoutWireGuard
#endif
