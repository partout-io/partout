// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Parses WireGuard configurations in `wg-quick` format.
// FIXME: #199, This is still broken, do not use in production
public final class StandardWireGuardParser {
    public init() {
    }
}

// MARK: - ConfigurationCoder

extension StandardWireGuardParser: ConfigurationCoder {
    public func configuration(from string: String) throws -> WireGuard.Configuration {
        try WireGuard.Configuration(fromWgQuickConfig: string)
    }

    public func string(from configuration: WireGuard.Configuration) -> String {
        configuration.asWgQuickConfig()
    }
}

// MARK: - ModuleImporter

extension StandardWireGuardParser: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        do {
            let cfg = try configuration(from: contents)
            let builder = WireGuardModule.Builder(configurationBuilder: cfg.builder())
            return try builder.tryBuild()
        } catch WireGuardParseError.invalidLine {
            throw PartoutError(.unknownImportedModule)
        } catch {
            throw PartoutError(.parsing, error)
        }
    }
}
