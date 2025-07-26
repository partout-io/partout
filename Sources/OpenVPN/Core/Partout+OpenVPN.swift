//
//  Partout+OpenVPN.swift
//  Partout
//
//  Created by Davide De Rosa on 3/27/24.
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

extension LoggerCategory {
    public static let openvpn = Self(rawValue: "openvpn")
}

extension TunnelEnvironmentKeys {
    public enum OpenVPN {
        public static let serverConfiguration = TunnelEnvironmentKey<PartoutOpenVPN.OpenVPN.Configuration>("OpenVPN.serverConfiguration")
    }
}

extension PartoutError.Code {
    public enum OpenVPN {
        public static let compressionMismatch = PartoutError.Code("OpenVPN.compressionMismatch")

        public static let connectionFailure = PartoutError.Code("OpenVPN.connectionFailure")

        public static let noRouting = PartoutError.Code("OpenVPN.noRouting")

        public static let otpRequired = PartoutError.Code("OpenVPN.otpRequired")

        public static let passphraseRequired = PartoutError.Code("OpenVPN.passphraseRequired")

        public static let serverShutdown = PartoutError.Code("OpenVPN.serverShutdown")

        public static let tlsFailure = PartoutError.Code("OpenVPN.tlsFailure")

        public static let unsupportedAlgorithm = PartoutError.Code("OpenVPN.unsupportedAlgorithm")

        public static let unsupportedOption = PartoutError.Code("OpenVPN.unsupportedOption")
    }
}
