// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
#if !PARTOUT_MONOLITH
internal import PartoutPortable
#endif
import Foundation

extension CControlPacket {
    typealias SerializationFunction = (
        _ dst: UnsafeMutablePointer<UInt8>,
        _ dstLength: Int,
        _ pkt: UnsafePointer<openvpn_ctrl>,
        _ alg: UnsafeMutablePointer<openvpn_ctrl_alg>,
        _ error: UnsafeMutablePointer<pp_crypto_error_code>
    ) -> Int

    func serialized() -> Data {
        let capacity = openvpn_ctrl_capacity(pkt)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { ptr in
            let headerLength = openvpn_packet_header_set(
                ptr.bytePointer,
                pkt.pointee.code,
                key,
                pkt.pointee.session_id
            )
            let serializedLength = openvpn_ctrl_serialize(
                ptr.bytePointer.advanced(by: headerLength),
                pkt
            )
            return headerLength + serializedLength
        }
        return dst.subdata(in: 0..<written)
    }

    func serialized(
        with crypto: pp_crypto_ctx,
        replayId: UInt32,
        timestamp: UInt32,
        function: SerializationFunction
    ) throws -> Data {
        var alg = openvpn_ctrl_alg(crypto: crypto, replay_id: replayId, timestamp: timestamp)
        let capacity = withUnsafePointer(to: alg) {
            openvpn_ctrl_capacity_alg(pkt, $0)
        }
        var dst = Data(count: capacity)
        let written = try dst.withUnsafeMutableBytes { dst in
            var enc_error = PPCryptoErrorNone
            let written = function(dst.bytePointer, capacity, pkt, &alg, &enc_error)
            guard written > 0 else {
                throw CCryptoError(enc_error)
            }
            return written
        }
        return dst.subdata(in: 0..<written)
    }
}
