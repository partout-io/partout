//
//  Obfuscator.swift
//  Partout
//
//  Created by Davide De Rosa on 11/4/22.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

internal import _PartoutCryptoOpenSSL_Cross
import _PartoutOpenVPNCore
internal import _PartoutOpenVPNOpenSSL_C
import Foundation
import PartoutCore

/// Processes data packets according to an obfuscation method.
final class Obfuscator {
    enum Direction {
        case outbound

        case inbound
    }

    private let obf: UnsafeMutablePointer<obf_t>

    init(method: OpenVPN.ObfuscationMethod?) {
        switch method {
        case .xormask(let mask):
            obf = mask.toData().withUnsafeBytes { maskPtr in
                obf_create(OBFMethodXORMask, maskPtr.bytePointer, mask.count)
            }
        case .xorptrpos:
            obf = obf_create(OBFMethodXORPtrPos, nil, 0)
        case .reverse:
            obf = obf_create(OBFMethodReverse, nil, 0)
        case .obfuscate(let mask):
            obf = mask.toData().withUnsafeBytes { maskPtr in
                obf_create(OBFMethodXORObfuscate, maskPtr.bytePointer, mask.count)
            }
        default:
            obf = obf_create(OBFMethodNone, nil, 0)
        }
    }

    deinit {
        obf_free(obf)
    }

    /**
     Returns an array of data packets processed according to the XOR method.

     - Parameter packets: The array of packets.
     - Parameter outbound: Set `true` if packets are outbound, `false` otherwise.
     - Returns: The array of packets after XOR processing.
     **/
    func processPackets(_ packets: [Data], direction: Direction) -> [Data] {
        packets.map {
            processPacket($0, direction: direction)
        }
    }

    /**
     Returns a data packet processed according to the XOR method.

     - Parameter packet: The packet.
     - Parameter direction: The direction of the packet.
     - Returns: The packet after XOR processing.
     **/
    func processPacket(_ packet: Data, direction: Direction) -> Data {
        var dst = [UInt8](repeating: 0, count: packet.count)
        packet.withUnsafeBytes { src in
            dst.withUnsafeMutableBytes { dst in
                switch direction {
                case .inbound:
                    obf_recv(obf, dst.bytePointer, src.bytePointer, packet.count)
                case .outbound:
                    obf_send(obf, dst.bytePointer, src.bytePointer, packet.count)
                }
            }
        }
        return Data(dst)
    }
}
