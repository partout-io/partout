//
//  OpenVPNProviderTemplate.swift
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

#if canImport(PartoutOpenVPN)

import Foundation
import PartoutCore
import PartoutOpenVPN

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
        _ ctx: PartoutLoggerContext,
        deviceId: String,
        moduleId: UUID,
        entity: ProviderEntity,
        options: Options?
    ) throws -> OpenVPNModule {
        let template = try entity.preset.template(ofType: OpenVPNProviderTemplate.self)
        var configurationBuilder = template.configuration.builder()
        configurationBuilder.authUserPass = true
        configurationBuilder.remotes = try template.remotes(
            ctx,
            with: entity.server,
            excludingHostname: options?.excludingHostname == true
        )

        // enforce default gateway
        configurationBuilder.routingPolicies = [.IPv4, .IPv6]

        var builder = OpenVPNModule.Builder(id: moduleId)
        builder.configurationBuilder = configurationBuilder
        if let credentials = options?.credentials {
            builder.credentials = credentials
        }
        return try builder.tryBuild()
    }
}

private extension OpenVPNProviderTemplate {
    func remotes(_ ctx: PartoutLoggerContext, with server: ProviderServer, excludingHostname: Bool) throws -> [ExtendedEndpoint] {
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
            pp_log(ctx, .providers, .error, "Excluding hostname but server has no ipAddresses either")
            throw PartoutError(.exhaustedEndpoints)
        }

        return remotes
    }
}

#endif
