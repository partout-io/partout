// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

final class DummyTunnelController: TunnelController {
    init() {
    }

    func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface {
        DummyTunnelinterface()
    }

    func clearTunnelSettings() async {
        // revert settings
    }

    func setReasserting(_ reasserting: Bool) {
    }

    func cancelTunnelConnection(with error: Error?) {
    }
}
