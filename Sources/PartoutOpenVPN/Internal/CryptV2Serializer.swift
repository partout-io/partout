// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ControlChannel {
    final class CryptV2Serializer: ControlChannelSerializer {
        private let wrappedKey: Data

        private let serializer: CryptSerializer

        init(_ ctx: PartoutLoggerContext, key: OpenVPN.StaticKey, wrappedKey: SecureData) throws {
            self.wrappedKey = wrappedKey.toData()
            serializer = try CryptSerializer(ctx, key: key)
        }

        func reset() {
            serializer.reset()
        }

        func serialize(packet: CrossPacket) throws -> Data {
            var data = try serializer.serialize(packet: packet)
            switch packet.code {
            case .hardResetClientV3, .controlWkcV1:
                data.append(wrappedKey)

            default:
                break
            }
            return data
        }

        func deserialize(data: Data, start: Int, end: Int?) throws -> CrossPacket {
            try serializer.deserialize(data: data, start: start, end: end)
        }
    }
}
