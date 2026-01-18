// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

typealias TLSFactory = @Sendable (TLSWrapper.Parameters) throws -> TLSProtocol

typealias DataPathFactory = @Sendable (
    DataPathWrapper.Parameters,
    CryptoKeys.PRF,
    PRNGProtocol
) throws -> DataPathProtocol
