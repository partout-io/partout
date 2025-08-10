// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
internal import _PartoutVendorsPortable
import Foundation
import PartoutCore
import PartoutOpenVPN

/// Processes data packets according to an obfuscation method.
final class PacketProcessor {
    enum Direction {
        case outbound

        case inbound
    }

    private let proc: UnsafeMutablePointer<pkt_proc_t>

    init(method: OpenVPN.ObfuscationMethod?) {
        switch method {
        case .xormask(let mask):
            proc = mask.toData().withUnsafeBytes { maskPtr in
                pkt_proc_create(PktProcMethodXORMask, maskPtr.bytePointer, mask.count)
            }
        case .xorptrpos:
            proc = pkt_proc_create(PktProcMethodXORPtrPos, nil, 0)
        case .reverse:
            proc = pkt_proc_create(PktProcMethodReverse, nil, 0)
        case .obfuscate(let mask):
            proc = mask.toData().withUnsafeBytes { maskPtr in
                pkt_proc_create(PktProcMethodXORObfuscate, maskPtr.bytePointer, mask.count)
            }
        default:
            proc = pkt_proc_create(PktProcMethodNone, nil, 0)
        }
    }

    deinit {
        pkt_proc_free(proc)
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
                    pkt_proc_recv(proc, dst.bytePointer, src.bytePointer, packet.count)
                case .outbound:
                    pkt_proc_send(proc, dst.bytePointer, src.bytePointer, packet.count)
                }
            }
        }
        return Data(dst)
    }

    func packets(fromStream stream: Data, until: inout Int) -> [Data] {
        stream.withUnsafeBytes { src in
            var packets: [Data] = []
            until = 0
            while true {
                var rcvd = 0
                let zd = pkt_proc_stream_recv(
                    proc,
                    src.bytePointer.advanced(by: until),
                    stream.count - until,
                    &rcvd
                )
                guard let zd else {
                    break
                }
                let packet = Data(zeroing: zd)
                packets.append(packet)
                until += rcvd
            }
            return packets
        }
    }

    func stream(fromPacket packet: Data) -> Data {
        let dst = pp_zd_create(pkt_proc_stream_send_bufsize(1, packet.count))
        _ = packet.withUnsafeBytes { src in
            pkt_proc_stream_send(
                proc,
                dst, 0,
                src.bytePointer, packet.count
            )
        }
        return Data(zeroing: dst)
    }

    func stream(fromPackets packets: [Data]) -> Data {
        let dst = pp_zd_create(pkt_proc_stream_send_bufsize(Int32(packets.count), packets.flatCount))
        var dstOffset = 0
        for packet in packets {
            packet.withUnsafeBytes { src in
                dstOffset = pkt_proc_stream_send(
                    proc,
                    dst, dstOffset,
                    src.bytePointer, packet.count
                )
            }
        }
        return Data(zeroing: dst)
    }
}
