// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
internal import PartoutOpenVPN_C

// TODO: #155, move more logic to C (replay protection, byte-aligned enc/dec zd)

final class CDataPath {
    private let mode: UnsafeMutablePointer<openvpn_dp_mode>

    private let encBuffer: UnsafeMutablePointer<pp_zd>

    private let decBuffer: UnsafeMutablePointer<pp_zd>

    private let replay: UnsafeMutablePointer<openvpn_replay>

    private let resizeStep: Int

    private let maxPacketId: UInt32

    private var outPacketId: UInt32

    init(mode: UnsafeMutablePointer<openvpn_dp_mode>, peerId: UInt32) {
        self.mode = mode
        openvpn_dp_mode_set_peer_id(mode, peerId)

        let oneKilo = 1024
        encBuffer = pp_zd_create(64 * oneKilo)
        decBuffer = pp_zd_create(64 * oneKilo)
        replay = openvpn_replay_create()
        resizeStep = 1024
        maxPacketId = .max - 10 * UInt32(oneKilo)
        outPacketId = .zero
    }

    deinit {
        openvpn_replay_free(replay)
        openvpn_dp_mode_free(mode)
        pp_zd_free(encBuffer)
        pp_zd_free(decBuffer)
    }
}

private extension CDataPath {
    func configure(
        cipherKey: Data?,
        hmacKey: Data?,
        block: (UnsafePointer<pp_zd>?, UnsafePointer<pp_zd>?) -> Void
    ) {
        let ck = cipherKey.map { data in
            data.withUnsafeBytes { ptr in
                pp_zd_create_from_data(ptr.bytePointer, data.count)
            }
        }
        let hk = hmacKey.map { data in
            data.withUnsafeBytes { ptr in
                pp_zd_create_from_data(ptr.bytePointer, data.count)
            }
        }
        block(ck, hk)
        if let ck {
            pp_zd_free(ck)
        }
        if let hk {
            pp_zd_free(hk)
        }
    }
}

// MARK: - Bulk encrypt/decrypt

extension CDataPath {
    func encrypt(_ packets: [Data], key: UInt8) throws -> [Data] {
        try packets.map {
            outPacketId += 1
            return try assembleAndEncrypt(
                $0,
                key: key,
                packetId: outPacketId,
                buf: nil
            )
        }
    }

    func decrypt(_ packets: [Data]) throws -> (packets: [Data], keepAlive: Bool) {
        var keepAlive = false
        let list = try packets.compactMap { encrypted -> Data? in

            // framing will throw if compressed (handled in openvpn_dp_framing_parse_*)
            let tuple = try decryptAndParse(
                encrypted,
                buf: nil
            )

            // throw on packet id overflow
            guard tuple.packetId <= maxPacketId else {
                throw OpenVPNDataPathError.overflow
            }
            // ignore replayed packet ids
            guard !openvpn_replay_is_replayed(replay, tuple.packetId) else {
                return nil
            }
            // detect keep-alive packet (ping)
            if tuple.isKeepAlive {
                keepAlive = true
                return nil
            }
            return tuple.data
        }
        return (list, keepAlive)
    }
}

// MARK: - Creating buffers (for testing)

extension CDataPath {
    func assembleAndEncrypt(
        _ packet: Data,
        key: UInt8,
        packetId: UInt32,
        withNewBuffer: Bool
    ) throws -> Data {
        let buf = withNewBuffer ? pp_zd_create(0) : nil
        return try assembleAndEncrypt(packet, key: key, packetId: packetId, buf: buf)
    }

    func decryptAndParse(
        _ packet: Data,
        withNewBuffer: Bool
    ) throws -> DataPathDecryptedAndParsedTuple {
        let buf = withNewBuffer ? pp_zd_create(0) : nil
        return try decryptAndParse(packet, buf: buf)
    }
}

extension CDataPath {
    func assemble(
        packetId: UInt32,
        payload: Data
    ) -> Data {
        let buf = pp_zd_create(openvpn_dp_mode_assemble_capacity(mode, payload.count))
        defer {
            pp_zd_free(buf)
        }
        return assemble(packetId: packetId, payload: payload, buf: buf)
    }

    func encrypt(
        key: UInt8,
        packetId: UInt32,
        assembled: Data
    ) throws -> Data {
        let buf = pp_zd_create(openvpn_dp_mode_encrypt_capacity(mode, assembled.count))
        defer {
            pp_zd_free(buf)
        }
        return try encrypt(key: key, packetId: packetId, assembled: assembled, buf: buf)
    }

    func decrypt(
        packet: Data
    ) throws -> DataPathDecryptedTuple {
        let buf = pp_zd_create(packet.count)
        defer {
            pp_zd_free(buf)
        }
        return try decrypt(packet: packet, buf: buf)
    }

    func parse(
        decrypted: Data,
        header: inout UInt8,
    ) throws -> Data {
        let buf = pp_zd_create(decrypted.count)
        defer {
            pp_zd_free(buf)
        }
        return try parse(decrypted: decrypted, header: &header, buf: buf)
    }
}

// MARK: - Reusing buffers

extension CDataPath {
    func assembleAndEncrypt(
        _ packet: Data,
        key: UInt8,
        packetId: UInt32,
        buf: UnsafeMutablePointer<pp_zd>?
    ) throws -> Data {
        let buf = buf ?? encBuffer
        resize(buf, for: openvpn_dp_mode_assemble_and_encrypt_capacity(mode, packet.count))
        return try packet.withUnsafeBytes { src in
            var error = openvpn_dp_error()
            let zd = openvpn_dp_mode_assemble_and_encrypt(
                mode,
                key,
                packetId,
                buf,
                src.bytePointer,
                packet.count,
                &error
            )
            guard let zd else {
                throw CDataPathError.error(for: error)
            }
            return Data(zeroing: zd)
        }
    }

    func decryptAndParse(
        _ packet: Data,
        buf: UnsafeMutablePointer<pp_zd>?
    ) throws -> DataPathDecryptedAndParsedTuple {
        let buf = buf ?? decBuffer
        resize(buf, for: packet.count)
        return try packet.withUnsafeBytes { src in
            var packetId: UInt32 = .zero
            var header: UInt8 = .zero
            var keepAlive: Bool = false
            var error = openvpn_dp_error()
            let zd = openvpn_dp_mode_decrypt_and_parse(
                mode,
                buf,
                &packetId,
                &header,
                &keepAlive,
                src.bytePointer,
                packet.count,
                &error
            )
            guard let zd else {
                throw CDataPathError.error(for: error)
            }
            let data = Data(zeroing: zd)
            return DataPathDecryptedAndParsedTuple(packetId, header, keepAlive, data)
        }
    }
}

extension CDataPath {
    func assemble(
        packetId: UInt32,
        payload: Data,
        buf: UnsafeMutablePointer<pp_zd>?
    ) -> Data {
        let buf = buf ?? encBuffer
        let inputCount = payload.count
        resize(buf, for: openvpn_dp_mode_assemble_capacity(mode, inputCount))
        return payload.withUnsafeBytes { input in
            let outLength = openvpn_dp_mode_assemble(
                mode,
                packetId,
                buf,
                input.bytePointer,
                inputCount
            )
            return Data(bytes: buf.pointee.bytes, count: outLength)
        }
    }

    func encrypt(
        key: UInt8,
        packetId: UInt32,
        assembled: Data,
        buf: UnsafeMutablePointer<pp_zd>?
    ) throws -> Data {
        let buf = buf ?? encBuffer
        let inputCount = assembled.count
        resize(buf, for: openvpn_dp_mode_encrypt_capacity(mode, inputCount))
        return try assembled.withUnsafeBytes { input in
            var error = openvpn_dp_error()
            let outLength = openvpn_dp_mode_encrypt(
                mode,
                key,
                packetId,
                buf,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outLength > 0 else {
                throw CDataPathError.error(for: error)
            }
            return Data(bytes: buf.pointee.bytes, count: outLength)
        }
    }

    func decrypt(
        packet: Data,
        buf: UnsafeMutablePointer<pp_zd>?
    ) throws -> DataPathDecryptedTuple {
        let buf = buf ?? decBuffer
        let inputCount = packet.count
        resize(buf, for: inputCount)
        return try packet.withUnsafeBytes { input in
            var packetId: UInt32 = 0
            var error = openvpn_dp_error()
            let outLength = openvpn_dp_mode_decrypt(
                mode,
                buf,
                &packetId,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outLength > 0 else {
                throw CDataPathError.error(for: error)
            }
            let data = Data(bytes: buf.pointee.bytes, count: outLength)
            return DataPathDecryptedTuple(packetId, data)
        }
    }

    func parse(
        decrypted: Data,
        header: inout UInt8,
        buf: UnsafeMutablePointer<pp_zd>?
    ) throws -> Data {
        let buf = buf ?? decBuffer
        var inputCopy = [UInt8](decrypted) // copy because parsed in place
        let inputCount = inputCopy.count
        resize(buf, for: inputCount)

        let decryptedOriginal = decrypted
        let parsed = try inputCopy.withUnsafeMutableBytes { input in
            var error = openvpn_dp_error()
            let outLength = openvpn_dp_mode_parse(
                mode,
                buf,
                &header,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outLength > 0 else {
                throw CDataPathError.error(for: error)
            }
            return Data(bytes: buf.pointee.bytes, count: outLength)
        }
        // this should never ever fail because of Swift compile checks
        assert(decryptedOriginal == decrypted, "Parsing is done in-place, work on a copy of decrypted")
        return parsed
    }
}

// MARK: -

private extension CDataPath {
    func resize(_ buf: UnsafeMutablePointer<pp_zd>, for count: Int) {
        guard buf.pointee.length < count else {
            return
        }
        var newCount = count + resizeStep
        newCount -= newCount % resizeStep // align to step boundary
        pp_zd_resize(buf, newCount)
    }
}
