// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Encodes a configuration into a string.
public protocol ConfigurationEncoder {
    associatedtype EncodedConfiguration

    func string(from configuration: EncodedConfiguration) throws -> String
}

/// Decodes a configuration from a string.
public protocol ConfigurationDecoder {
    associatedtype DecodedConfiguration

    func configuration(from string: String) throws -> DecodedConfiguration
}

/// Implements both ``ConfigurationEncoder`` and ``ConfigurationDecoder``.
public protocol ConfigurationCoder: ConfigurationEncoder, ConfigurationDecoder where EncodedConfiguration == DecodedConfiguration {
}
