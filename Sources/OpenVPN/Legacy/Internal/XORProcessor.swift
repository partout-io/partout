//
//  XORProcessor.swift
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

internal import _PartoutCryptoOpenSSL_ObjC
import Foundation
import PartoutCore
import PartoutOpenVPN
internal import PartoutOpenVPNLegacy_ObjC

/// Processes data packets according to a XOR method.
struct XORProcessor {
    private enum RawMethod {
        case xormask(mask: ZeroingData)

        case xorptrpos

        case reverse

        case obfuscate(mask: ZeroingData)

        init(_ method: OpenVPN.ObfuscationMethod) {
            switch method {
            case .xormask(let mask):
                self = .xormask(mask: mask.zData)
            case .xorptrpos:
                self = .xorptrpos
            case .reverse:
                self = .reverse
            case .obfuscate(let mask):
                self = .obfuscate(mask: mask.zData)
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
    func processPackets(_ packets: [Data], outbound: Bool) -> [Data] {
        packets.map {
            processPacket($0, outbound: outbound)
        }
    }

    /**
     Returns a data packet processed according to the XOR method.

     - Parameter packet: The packet.
     - Parameter outbound: Set `true` if packet is outbound, `false` otherwise.
     - Returns: The packet after XOR processing.
     **/
    func processPacket(_ packet: Data, outbound: Bool) -> Data {
        var dst = [UInt8](packet)
        let dstLength = dst.count
        switch method {
        case .xormask(let mask):
            dst.withUnsafeMutableBytes { dst in
                xor_mask_legacy(dst.bytePointer, dst.bytePointer, dstLength, mask)
            }
        case .xorptrpos:
            dst.withUnsafeMutableBytes { dst in
                xor_ptrpos_legacy(dst.bytePointer, dst.bytePointer, dstLength)
            }
        case .reverse:
            dst.withUnsafeMutableBytes { dst in
                xor_reverse_legacy(dst.bytePointer, dst.bytePointer, dstLength)
            }
        case .obfuscate(let mask):
            dst.withUnsafeMutableBytes { dst in
                xor_obfuscate_legacy(dst.bytePointer, dst.bytePointer, dstLength, mask, outbound)
            }
        @unknown default:
            assertionFailure("Unhandled XOR method: \(method)")
        }
        return Data(dst)
    }
}
