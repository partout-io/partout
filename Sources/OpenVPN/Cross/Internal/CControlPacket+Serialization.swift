//
//  CControlPacket+Serialization.swift
//  Partout
//
//  Created by Davide De Rosa on 6/25/25.
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

internal import _PartoutOpenVPN_C
internal import _PartoutVendorsPortable
import Foundation

extension CControlPacket {
    typealias SerializationFunction = (
        _ dst: UnsafeMutablePointer<UInt8>,
        _ dstLength: Int,
        _ pkt: UnsafePointer<ctrl_pkt_t>,
        _ alg: UnsafeMutablePointer<ctrl_pkt_alg>,
        _ error: UnsafeMutablePointer<crypto_error_code>
    ) -> Int

    func serialized() -> Data {
        let capacity = ctrl_pkt_capacity(pkt)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { ptr in
            let headerLength = packet_header_set(
                ptr.bytePointer,
                pkt.pointee.code,
                key,
                pkt.pointee.session_id
            )
            let serializedLength = ctrl_pkt_serialize(
                ptr.bytePointer.advanced(by: headerLength),
                pkt
            )
            return headerLength + serializedLength
        }
        return dst.subdata(in: 0..<written)
    }

    func serialized(
        with crypto: crypto_ctx,
        replayId: UInt32,
        timestamp: UInt32,
        function: SerializationFunction
    ) throws -> Data {
        var alg = ctrl_pkt_alg(crypto: crypto, replay_id: replayId, timestamp: timestamp)
        let capacity = withUnsafePointer(to: alg) {
            ctrl_pkt_capacity_alg(pkt, $0)
        }
        var dst = Data(count: capacity)
        let written = try dst.withUnsafeMutableBytes { dst in
            var enc_error = CryptoErrorNone
            let written = function(dst.bytePointer, capacity, pkt, &alg, &enc_error)
            guard written > 0 else {
                throw CCryptoError(enc_error)
            }
            return written
        }
        return dst.subdata(in: 0..<written)
    }
}
