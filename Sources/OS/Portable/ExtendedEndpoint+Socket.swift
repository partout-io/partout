// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension ExtendedEndpoint {
    var socketProto: pp_socket_proto {
        switch proto.socketType.plainType {
        case .udp:
            return PPSocketProtoUDP
        case .tcp:
            return PPSocketProtoTCP
        }
    }
}
