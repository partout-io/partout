//
//  DataPath.swift
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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

internal import _PartoutCryptoOpenSSL_C
internal import _PartoutOpenVPNOpenSSL_C
import Foundation

// TODO: ###, move more logic to C (replay protection, byte-aligned enc/dec zd)

final class DataPath {
    typealias DecryptedTuple = (
        packetId: UInt32,
        header: UInt8,
        isKeepAlive: Bool,
        data: Data
    )

    private let mode: UnsafeMutablePointer<dp_mode_t>

    private let encBuffer: UnsafeMutablePointer<zeroing_data_t>

    private let decBuffer: UnsafeMutablePointer<zeroing_data_t>

    private let replay: UnsafeMutablePointer<replay_t>

    private let resizeStep: Int

    private let maxPacketId: UInt32

    private var outPacketId: UInt32

    init(mode: UnsafeMutablePointer<dp_mode_t>, peerId: UInt32) {
        self.mode = mode
        dp_mode_set_peer_id(mode, peerId)

        let oneKilo = 1024
        encBuffer = zd_create(64 * oneKilo)
        decBuffer = zd_create(64 * oneKilo)
        replay = replay_create()
        resizeStep = 1024
        maxPacketId = .max - 10 * UInt32(oneKilo)
        outPacketId = .zero
    }

    deinit {
        zd_free(encBuffer)
        zd_free(decBuffer)
    }

    func configureEncryption(cipherKey: Data?, hmacKey: Data?) {
        configure(cipherKey: cipherKey, hmacKey: hmacKey) {
            dp_mode_configure_enc(mode, $0, $1)
        }
    }

    func configureDecryption(cipherKey: Data?, hmacKey: Data?) {
        configure(cipherKey: cipherKey, hmacKey: hmacKey) {
            dp_mode_configure_dec(mode, $0, $1)
        }
    }
}

private extension DataPath {
    func configure(
        cipherKey: Data?,
        hmacKey: Data?,
        block: (UnsafePointer<zeroing_data_t>?, UnsafePointer<zeroing_data_t>?) -> Void
    ) {
        let ck = cipherKey.map { data in
            data.withUnsafeBytes { ptr in
                zd_create_from_data(ptr.bytePointer, data.count)
            }
        }
        let hk = hmacKey.map { data in
            data.withUnsafeBytes { ptr in
                zd_create_from_data(ptr.bytePointer, data.count)
            }
        }
        block(ck, hk)
        if let ck {
            zd_free(ck)
        }
        if let hk {
            zd_free(hk)
        }
    }
}

// MARK: - Bulk encrypt/decrypt

extension DataPath {
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

            // framing will throw if compressed (handled in dp_framing_parse_*)
            let tuple = try decryptAndParse(
                encrypted,
                buf: nil
            )

            // throw on packet id overflow
            guard tuple.packetId <= maxPacketId else {
                throw DataPathError.path(DataPathErrorOverflow)
            }
            // ignore replayed packet ids
            guard !replay_is_replayed(replay, tuple.packetId) else {
                return nil
            }
            // detect keep-alive packet (ping)
            if tuple.isKeepAlive {
                keepAlive = true
            }
            return tuple.data
        }
        return (list, keepAlive)
    }
}

// MARK: - Creating buffers (for testing)

extension DataPath {
    func assembleAndEncrypt(
        _ packet: Data,
        key: UInt8,
        packetId: UInt32,
        withNewBuffer: Bool
    ) throws -> Data {
        let buf = withNewBuffer ? zd_create(0) : nil
        return try assembleAndEncrypt(packet, key: key, packetId: packetId, buf: buf)
    }

    func decryptAndParse(
        _ packet: Data,
        withNewBuffer: Bool
    ) throws -> DecryptedTuple {
        let buf = withNewBuffer ? zd_create(0) : nil
        return try decryptAndParse(packet, buf: buf)
    }
}

extension DataPath {
    func assemble(
        packetId: UInt32,
        payload: Data
    ) -> Data {
        let buf = zd_create(dp_mode_assemble_capacity(mode, payload.count))
        defer {
            zd_free(buf)
        }
        return assemble(packetId: packetId, payload: payload, buf: buf)
    }

    func encrypt(
        key: UInt8,
        packetId: UInt32,
        assembled: Data
    ) throws -> Data {
        let buf = zd_create(dp_mode_encrypt_capacity(mode, assembled.count))
        defer {
            zd_free(buf)
        }
        return try encrypt(key: key, packetId: packetId, assembled: assembled, buf: buf)
    }

    func decrypt(
        packet: Data
    ) throws -> (packetId: UInt32, data: Data) {
        let buf = zd_create(packet.count)
        defer {
            zd_free(buf)
        }
        return try decrypt(packet: packet, buf: buf)
    }

    func parse(
        decrypted: Data,
        header: inout UInt8,
    ) throws -> Data {
        let buf = zd_create(decrypted.count)
        defer {
            zd_free(buf)
        }
        return try parse(decrypted: decrypted, header: &header, buf: buf)
    }
}

// MARK: - Reusing buffers

extension DataPath {
    func assembleAndEncrypt(
        _ packet: Data,
        key: UInt8,
        packetId: UInt32,
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) throws -> Data {
        let buf = buf ?? encBuffer
        resize(buf, for: dp_mode_assemble_and_encrypt_capacity(mode, packet.count))
        return try packet.withUnsafeBytes { src in
            var error = dp_error_t()
            let zd = dp_mode_assemble_and_encrypt(
                mode,
                key,
                packetId,
                buf,
                src.bytePointer,
                packet.count,
                &error
            )
            guard let zd else {
                throw DataPathError(error) ?? .generic
            }
            return NSData(bytesNoCopy: zd.pointee.bytes, length: zd.pointee.length) as Data
        }
    }

    func decryptAndParse(
        _ packet: Data,
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) throws -> DecryptedTuple {
        let buf = buf ?? decBuffer
        resize(buf, for: packet.count)
        return try packet.withUnsafeBytes { src in
            var packetId: UInt32 = .zero
            var header: UInt8 = .zero
            var keepAlive: Bool = false
            var error = dp_error_t()
            let zd = dp_mode_decrypt_and_parse(
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
                throw DataPathError(error) ?? .generic
            }
            let data = NSData(bytesNoCopy: zd.pointee.bytes, length: zd.pointee.length) as Data
            return (packetId, header, keepAlive, data)
        }
    }
}

extension DataPath {
    func assemble(
        packetId: UInt32,
        payload: Data,
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) -> Data {
        let buf = buf ?? encBuffer
        let inputCount = payload.count
        resize(buf, for: dp_mode_assemble_capacity(mode, inputCount))
        return payload.withUnsafeBytes { input in
            let outLength = dp_mode_assemble(
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
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) throws -> Data {
        let buf = buf ?? encBuffer
        let inputCount = assembled.count
        resize(buf, for: dp_mode_encrypt_capacity(mode, inputCount))
        return try assembled.withUnsafeBytes { input in
            var error = dp_error_t()
            let outLength = dp_mode_encrypt(
                mode,
                key,
                packetId,
                buf,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outLength > 0 else {
                throw DataPathError(error) ?? .generic
            }
            return Data(bytes: buf.pointee.bytes, count: outLength)
        }
    }

    func decrypt(
        packet: Data,
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) throws -> (packetId: UInt32, data: Data) {
        let buf = buf ?? decBuffer
        let inputCount = packet.count
        resize(buf, for: inputCount)
        return try packet.withUnsafeBytes { input in
            var packetId: UInt32 = 0
            var error = dp_error_t()
            let outLength = dp_mode_decrypt(
                mode,
                buf,
                &packetId,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outLength > 0 else {
                throw DataPathError(error) ?? .generic
            }
            let data = Data(bytes: buf.pointee.bytes, count: outLength)
            return (packetId, data)
        }
    }

    func parse(
        decrypted: Data,
        header: inout UInt8,
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) throws -> Data {
        let buf = buf ?? decBuffer
        var inputCopy = [UInt8](decrypted) // copy because parsed in place
        let inputCount = inputCopy.count
        resize(buf, for: inputCount)

        let decryptedOriginal = decrypted
        let parsed = try inputCopy.withUnsafeMutableBytes { input in
            var error = dp_error_t()
            let outLength = dp_mode_parse(
                mode,
                buf,
                &header,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outLength > 0 else {
                throw DataPathError(error) ?? .generic
            }
            return Data(bytes: buf.pointee.bytes, count: outLength)
        }
        // this should never ever fail because of Swift compile checks
        assert(decryptedOriginal == decrypted, "Parsing is done in-place, work on a copy of decrypted")
        return parsed
    }
}

// MARK: -

private extension DataPath {
    func resize(_ buf: UnsafeMutablePointer<zeroing_data_t>, for count: Int) {
        guard buf.pointee.length < count else {
            return
        }
        var newCount = count + resizeStep
        newCount -= newCount % resizeStep // align to step boundary
        zd_resize(buf, newCount)
    }
}
