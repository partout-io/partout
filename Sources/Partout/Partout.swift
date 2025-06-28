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

#if canImport(_PartoutOpenVPNCore)
@_exported import _PartoutOpenVPNCore
#endif
#if canImport(_PartoutWireGuardCore)
@_exported import _PartoutWireGuardCore
#endif
