// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

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
