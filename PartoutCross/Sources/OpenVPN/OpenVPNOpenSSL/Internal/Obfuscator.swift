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
struct Obfuscator {
    enum Direction {
        case outbound

        case inbound
    }

    private enum RawMethod {
        case xormask(mask: CZeroingData)

        case xorptrpos

        case reverse

        case obfuscate(mask: CZeroingData)

        init(_ method: OpenVPN.ObfuscationMethod) {
            switch method {
            case .xormask(let mask):
                self = .xormask(mask: mask.czData)
            case .xorptrpos:
                self = .xorptrpos
            case .reverse:
                self = .reverse
            case .obfuscate(let mask):
                self = .obfuscate(mask: mask.czData)
            }
        }
    }

    private let method: RawMethod

    init(method: OpenVPN.ObfuscationMethod) {
        self.method = RawMethod(method)
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
        var dst = [UInt8](packet)
        let dstLength = dst.count
        switch method {
        case .xormask(let mask):
            dst.withUnsafeMutableBytes { dst in
                obf_xor_mask(dst.bytePointer, dstLength, mask.bytes, mask.length)
            }
        case .xorptrpos:
            dst.withUnsafeMutableBytes { dst in
                obf_xor_ptrpos(dst.bytePointer, dstLength)
            }
        case .reverse:
            dst.withUnsafeMutableBytes { dst in
                obf_reverse(dst.bytePointer, dstLength)
            }
        case .obfuscate(let mask):
            dst.withUnsafeMutableBytes { dst in
                obf_xor_obfuscate(
                    dst.bytePointer,
                    dstLength,
                    mask.bytes,
                    mask.length,
                    direction == .outbound
                )
            }
        @unknown default:
            assertionFailure("Unhandled XOR method: \(method)")
            break
        }
        return Data(dst)
    }
}
