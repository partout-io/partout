// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore

typealias TLSFactory = @Sendable (TLSWrapper.Parameters) throws -> TLSProtocol

typealias DataPathFactory = @Sendable (
    DataPathWrapper.Parameters,
    CryptoKeys.PRF,
    PRNGProtocol
) throws -> DataPathProtocol
