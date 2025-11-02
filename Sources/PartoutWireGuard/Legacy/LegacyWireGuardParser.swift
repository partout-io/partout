// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Parses WireGuard configurations in `wg-quick` format.
@available(*, deprecated, message: "Use StandardWireGuardParser")
public final class LegacyWireGuardParser {
    public init() {
    }
}

// MARK: - ConfigurationCoder

extension LegacyWireGuardParser: ConfigurationCoder {
    public func configuration(from string: String) throws -> WireGuard.Configuration {
        try WireGuard.Configuration(wgQuickConfig: string)
    }

    public func string(from configuration: WireGuard.Configuration) throws -> String {
        try configuration.toWgQuickConfig()
    }
}

// MARK: - ModuleImporter

extension LegacyWireGuardParser: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        do {
            let cfg = try configuration(from: contents)
            let builder = WireGuardModule.Builder(configurationBuilder: cfg.builder())
            return try builder.build()
        } catch WireGuardParseError.invalidLine {
            throw PartoutError(.unknownImportedModule)
        } catch {
            throw PartoutError(.parsing, error)
        }
    }
}
