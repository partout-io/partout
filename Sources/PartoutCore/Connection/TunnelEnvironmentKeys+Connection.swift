// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension TunnelEnvironmentKeys {
    public static let connectionStatus = TunnelEnvironmentKey<ConnectionStatus>("connectionStatus")

    public static let dataCount = TunnelEnvironmentKey<DataCount>("dataCount")

    public static let lastErrorCode = TunnelEnvironmentKey<PartoutError.Code>("lastErrorCode")
}
