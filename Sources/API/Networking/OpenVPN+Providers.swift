//
//  OpenVPN+Providers.swift
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

import _PartoutOpenVPN
import Foundation
import GenericJSON
import PartoutCore

// MARK: Resolution

public struct OpenVPNProviderResolver: ProviderModuleResolver {
    public var moduleType: ModuleType {
        .openVPN
    }

    public init() {
    }

    public func resolved(from providerModule: ProviderModule) throws -> Module {
        try providerModule.compiled(withTemplate: OpenVPNProviderTemplate.self)
    }
}

public struct OpenVPNProviderTemplate: Codable, Sendable {
    public let configuration: OpenVPN.Configuration

    public let endpoints: [EndpointProtocol]

    public init(configuration: OpenVPN.Configuration, endpoints: [EndpointProtocol]) {
        self.configuration = configuration
        self.endpoints = endpoints
    }
}

extension OpenVPNProviderTemplate {
    public struct Options: ProviderOptions {
        public var credentials: OpenVPN.Credentials?

        public var excludingHostname = false

        public init() {
        }
    }
}

extension OpenVPNProviderTemplate: ProviderTemplateCompiler {
    public static func compiled(
        with id: UUID,
        entity: ProviderEntity,
        options: Options?
    ) throws -> OpenVPNModule {
        let template = try entity.preset.template(ofType: OpenVPNProviderTemplate.self)
        var configurationBuilder = template.configuration.builder()
        configurationBuilder.authUserPass = true
        configurationBuilder.remotes = try template.remotes(
            with: entity.server,
            excludingHostname: options?.excludingHostname == true
        )

        // enforce default gateway
        configurationBuilder.routingPolicies = [.IPv4, .IPv6]

        var builder = OpenVPNModule.Builder(id: id)
        builder.configurationBuilder = configurationBuilder
        if let credentials = options?.credentials {
            builder.credentials = credentials
        }
        return try builder.tryBuild()
    }
}

private extension OpenVPNProviderTemplate {
    func remotes(with server: ProviderServer, excludingHostname: Bool) throws -> [ExtendedEndpoint] {
        var remotes: [ExtendedEndpoint] = []

        if !excludingHostname, let hostname = server.hostname {
            try endpoints.forEach { ep in
                remotes.append(try .init(hostname, ep))
            }
        }
        endpoints.forEach { ep in
            server.ipAddresses?.forEach { data in
                guard let addr = Address(data: data) else {
                    return
                }
                remotes.append(.init(addr, ep))
            }
        }
        guard !remotes.isEmpty else {
            pp_log(.api, .error, "Excluding hostname but server has no ipAddresses either")
            throw PartoutError(.exhaustedEndpoints)
        }

        return remotes
    }
}

// MARK: - Customization

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
// MARK: - Legacy

extension OpenVPNLegacyProviderEntity {
    public func upgraded() throws -> ProviderEntity {
        ProviderEntity(
            server: server.upgraded(),
            preset: try preset.upgraded(),
            heuristic: heuristic?.upgraded()
        )
    }
}

private extension OpenVPNLegacyProviderServer {
    func upgraded() -> ProviderServer {
        ProviderServer(
            metadata: ProviderServer.Metadata(
                providerId: ProviderID(rawValue: metadata.providerId.rawValue),
                categoryName: metadata.categoryName,
                countryCode: metadata.countryCode,
                otherCountryCodes: metadata.otherCountryCodes,
                area: metadata.area
            ),
            serverId: metadata.serverId,
            hostname: hostname,
            ipAddresses: ipAddresses,
            supportedModuleTypes: [.openVPN],
            supportedPresetIds: metadata.supportedPresetIds
        )
    }
}

private extension OpenVPNLegacyProviderPreset {
    func upgraded() throws -> ProviderPreset {
        let newTemplate = OpenVPNProviderTemplate(configuration: template, endpoints: endpoints)
        let newTemplateData = try JSONEncoder().encode(newTemplate)
        return ProviderPreset(
            providerId: ProviderID(rawValue: providerId.rawValue),
            presetId: presetId,
            description: description,
            moduleType: .openVPN,
            templateData: newTemplateData
        )
    }
}

private extension OpenVPNLegacyProviderHeuristic {
    func upgraded() -> ProviderHeuristic? {
        switch self {
        case .sameCountry(let countryCode):
            return .sameCountry(countryCode)

        case .sameRegion(let region):
            return .sameRegion(ProviderRegion(
                countryCode: region.countryCode,
                area: region.area
            ))
        }
    }
}
