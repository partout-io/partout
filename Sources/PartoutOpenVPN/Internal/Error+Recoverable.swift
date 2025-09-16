// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension Error {
    var isOpenVPNRecoverable: Bool {
        let ppError = PartoutError(self)
        if ppRecoverableCodes.contains(ppError.code) {
            return true
        }
        if case .recoverable = ppError.reason as? OpenVPNSessionError {
            return true
        }
        return false
    }
}

private let ppRecoverableCodes: [PartoutError.Code] = [
    .timeout,
    .linkFailure,
    .networkChanged,
    .OpenVPN.connectionFailure,
    .OpenVPN.serverShutdown
]
