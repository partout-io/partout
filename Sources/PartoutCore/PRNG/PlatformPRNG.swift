// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// Implementation of ``PRNGProtocol`` with the OS C library from MiniFoundation.
public final class PlatformPRNG: PRNGProtocol {
    public init() {
    }

    public func data(length: Int) -> Data {
        Data(PRNG().data(length: length))
    }
}
