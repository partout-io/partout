// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutPortable_C

extension ExtendedEndpoint {
    public var socketProto: pp_socket_proto {
        switch plainSocketType {
        case .udp:
            return PPSocketProtoUDP
        case .tcp:
            return PPSocketProtoTCP
        }
    }
}
