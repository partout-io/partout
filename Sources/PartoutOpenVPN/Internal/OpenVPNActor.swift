// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@globalActor
final class OpenVPNActor {
    actor Shared {}

    static let shared = Shared()
}
