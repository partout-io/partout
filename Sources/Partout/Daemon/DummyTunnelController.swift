// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

final class DummyTunnelController: TunnelController {
    let profile: Profile

    init(profile: Profile) {
        self.profile = profile
    }

    func setTunnelSettings(with info: TunnelRemoteInfo?) async throws {
        // set routes
    }

    func clearTunnelSettings() async {
        // revert settings
    }

    func setReasserting(_ reasserting: Bool) {
    }

    func cancelTunnelConnection(with error: Error?) {
    }
}
