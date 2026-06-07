// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct LinkProcessor: @unchecked Sendable {
    private let proc: PacketProcessor
    let beforeRead: @Sendable ([Data]) throws -> [Data]
    let beforeWrite: @Sendable ([Data]) throws -> [Data]

    init(proc: PacketProcessor, isReliable: Bool) {
        self.proc = proc
        if isReliable {
            nonisolated(unsafe) var buffer = Data()
            beforeRead = {
                // FIXME: #214, TCP is very slow
                buffer.reserveCapacity(buffer.count + $0.flatCount)
                for p in $0 {
                    buffer.append(p)
                }
                var until = 0
                let processedPackets = proc.packets(fromStream: buffer, until: &until)
                buffer = buffer.subdata(in: until..<buffer.count)
                return processedPackets
            }
            beforeWrite = {
                let stream = proc.stream(fromPackets: $0)
                guard !stream.isEmpty else { return [] }
                return [stream]
            }
        } else {
            beforeRead = {
                proc.processPackets($0, direction: .inbound)
            }
            beforeWrite = {
                proc.processPackets($0, direction: .outbound)
            }
        }
    }
}
