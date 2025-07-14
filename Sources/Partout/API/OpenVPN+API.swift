//
//  OpenVPN+API.swift
//  Partout
//
//  Created by Davide De Rosa on 12/2/24.
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

#if canImport(PartoutAPI) && canImport(_PartoutOpenVPNCore)

import _PartoutOpenVPNCore
import Foundation
import GenericJSON
import PartoutCore

// FIXME: passepartout#507, ridiculously complex
extension OpenVPNModule: ProviderCustomizationSupporting {
    public static let providerCustomizationType = OpenVPN.ProviderCustomization.self
}

extension OpenVPN {
    public struct ProviderCustomization {
        public struct Credentials {
            public enum Purpose: String {
                case web

                case specific
            }

            public enum Option: String {
                case noPassword
            }

            public let purpose: Purpose

            public let options: Set<Option>?

            public let url: URL?
        }

        public let credentials: Credentials
    }
}

extension OpenVPN.ProviderCustomization: UserInfoCodable {
    public init?(userInfo: AnyHashable?) {
        guard let userInfo else {
            return nil
        }
        guard let json = userInfo as? JSON else {
            assertionFailure("Expected JSON object from PartoutAPI 'metadata.configurations'")
            return nil
        }
        guard let credentials = json.credentials else {
            return nil
        }
        let purpose = credentials.purpose?.stringValue
        let options = Set(credentials.options?.arrayValue?.compactMap {
            $0.stringValue.map {
                Credentials.Option(rawValue: $0)
            } ?? nil
        } ?? [])
        switch purpose {
        case "web":
            self.credentials = .init(purpose: .web, options: options, url: nil)
        case "specific":
            let url = credentials.url?.stringValue.map {
                URL(string: $0)
            }
            self.credentials = .init(purpose: .specific, options: options, url: url ?? nil)
        default:
            self.credentials = .init(purpose: .web, options: options, url: nil)
        }
    }

    public var userInfo: AnyHashable? {
        var credentialsMap: [String: AnyHashable] = [:]
        credentialsMap["purpose"] = credentials.purpose.rawValue
        if let options = credentials.options {
            credentialsMap["options"] = options.map(\.rawValue)
        }
        if let url = credentials.url {
            credentialsMap["url"] = url.absoluteString
        }
        return ["credentials": credentialsMap]
    }
}

#endif
