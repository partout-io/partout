// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
#endif

/// Provides methods to parse a ``OpenVPN/Configuration`` from an .ovpn configuration file.
///
/// The parser recognizes most of the relevant options and normally you should not face big limitations.
///
/// ### Unsupported options:
///
/// - UDP fragmentation, i.e. `--fragment`
/// - Compression via `--compress` other than empty or `lzo`
/// - Connecting via proxy
/// - External file references (inline `<block>` only)
/// - Static key encryption (non-TLS)
/// - `<connection>` blocks
/// - `net_gateway` literals in routes
///
/// ### Ignored options:
///
/// - Some MTU overrides
///     - `--link-mtu` and variants
///     - `--mssfix`
/// - Static client-side routes
///
/// Many other flags are ignored too but it's normally not an issue.
///
public final class StandardOpenVPNParser {

    // XXX: parsing is very optimistic

    /// Result of the parser.
    public struct Result {

        /// Original URL of the configuration file, if parsed from an URL.
        public let url: URL?

        /// The overall parsed ``OpenVPN/Configuration``.
        public let configuration: OpenVPN.Configuration

        /// The inline credentials.
        public let credentials: OpenVPN.Credentials?

        /// Holds an optional `ConfigurationError` that didn't block the parser, but it would be worth taking care of.
        public let warning: StandardOpenVPNParserError?
    }

    private let supportsLZO: Bool

    /// The decrypter for private keys.
    private let decrypter: (KeyDecrypter & Sendable)?

    private let rxOptions: [(option: OpenVPN.Option, rx: NSRegularExpression)] = OpenVPN.Option.allCases.compactMap {
        do {
            let rx = try $0.regularExpression()
            return ($0, rx)
        } catch {
            assertionFailure("Unable to build regex for '\($0.rawValue)': \(error)")
            return nil
        }
    }

    public init(supportsLZO: Bool, decrypter: (KeyDecrypter & Sendable)?) {
        self.supportsLZO = supportsLZO
        self.decrypter = decrypter
    }

    /// Parses a configuration from a .ovpn file.
    ///
    /// - Parameters:
    ///   - url: The URL of the configuration file.
    ///   - passphrase: The optional passphrase for encrypted data.
    /// - Returns: The ``Result`` outcome of the parsing.
    /// - Throws: If the configuration file is wrong or incomplete.
    public func parsed(
        fromURL url: URL,
        passphrase: String? = nil
    ) throws -> Result {
        let contents = try String(contentsOf: url)
        return try parsed(
            fromContents: contents,
            passphrase: passphrase,
            originalURL: url
        )
    }

    /// Parses a configuration from a string.
    ///
    /// - Parameters:
    ///   - contents: The contents of the configuration file.
    ///   - passphrase: The optional passphrase for encrypted data.
    ///   - originalURL: The optional original URL of the configuration file.
    /// - Returns: The ``Result`` outcome of the parsing.
    /// - Throws: If the configuration file is wrong or incomplete.
    public func parsed(
        fromContents contents: String,
        passphrase: String? = nil,
        originalURL: URL? = nil
    ) throws -> Result {
        let lines = contents.trimmedLines()
        return try parsed(
            fromLines: lines,
            isClient: true,
            passphrase: passphrase,
            originalURL: originalURL
        )
    }

    /// Parses a configuration from an array of lines.
    ///
    /// - Parameters:
    ///   - lines: The array of lines holding the configuration.
    ///   - isClient: Enables additional checks for client configurations.
    ///   - passphrase: The optional passphrase for encrypted data.
    ///   - originalURL: The optional original URL of the configuration file.
    /// - Returns: The ``Result`` outcome of the parsing.
    /// - Throws: If the configuration file is wrong or incomplete.
    public func parsed(
        fromLines lines: [String],
        isClient: Bool = false,
        passphrase: String? = nil,
        originalURL: URL? = nil
    ) throws -> Result {
        try privateParsed(
            fromLines: lines,
            isClient: isClient,
            passphrase: passphrase,
            originalURL: originalURL
        )
    }
}

private extension StandardOpenVPNParser {
    func privateParsed(
        fromLines lines: [String],
        isClient: Bool = false,
        passphrase: String? = nil,
        originalURL: URL? = nil
    ) throws -> Result {
        var builder = Builder(supportsLZO: supportsLZO, decrypter: decrypter)
        var isUnknown = true
        for line in lines {
            let found = try enumerateOptions(in: line) {
                try builder.putOption($0, line: line, components: $1)
            }
            guard found else {
                builder.putLine(line)
                continue
            }
            isUnknown = false
        }
        guard !isUnknown else {
            throw StandardOpenVPNParserError.invalidFormat
        }
        let result = try builder.build(isClient: isClient, passphrase: passphrase)
        return Result(
            url: originalURL,
            configuration: result.configuration,
            credentials: result.credentials,
            warning: result.warning
        )
    }
}

// MARK: - ConfigurationDecoder

extension StandardOpenVPNParser: ConfigurationDecoder {
    public func configuration(from string: String) throws -> OpenVPN.Configuration {
        try parsed(fromContents: string).configuration
    }
}

// MARK: - ModuleImporter

extension StandardOpenVPNParser: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        do {
            let passphrase = object as? String
            let result = try parsed(fromContents: contents, passphrase: passphrase)
            var builder = OpenVPNModule.Builder(configurationBuilder: result.configuration.builder())
            builder.credentials = result.credentials
            return try builder.tryBuild()
        } catch let error as StandardOpenVPNParserError {
            switch error {
            case .encryptionPassphrase:
                throw PartoutError(.OpenVPN.passphraseRequired)
            case .invalidFormat:
                throw PartoutError(.unknownImportedModule)
            default:
                throw error.asPartoutError
            }
        } catch {
            throw PartoutError(.parsing, error)
        }
    }
}

// MARK: - Helpers

private extension StandardOpenVPNParser {
    func enumerateOptions(
        in line: String,
        completion: @escaping (_ option: OpenVPN.Option, _ components: [String]) throws -> Void
    ) throws -> Bool {
        assert(rxOptions.first?.option == .continuation)
        for pair in rxOptions {
            var lastError: Error?
            if pair.rx.enumerateSpacedComponents(in: line, using: { components in
                do {
                    try completion(pair.option, components)
                } catch {
                    lastError = error
                }
            }) {
                if let lastError {
                    throw lastError
                }
                return true
            }
        }
        return false
    }
}

extension NSRegularExpression {
    func enumerateSpacedComponents(in string: String, using block: @escaping ([String]) -> Void) -> Bool {
        var found = false
        enumerateMatches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.count)
        ) { result, _, _ in
            guard let result else {
                return
            }
            let match = (string as NSString)
                .substring(with: result.range)
            let components = match
                .components(separatedBy: " ")
                .filter {
                    !$0.isEmpty
                }
            found = true
            block(components)
        }
        return found
    }
}

private extension String {
    func trimmedLines() -> [String] {
        components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\s", with: " ", options: .regularExpression)
            }
            .filter {
                !$0.isEmpty
            }
    }
}
