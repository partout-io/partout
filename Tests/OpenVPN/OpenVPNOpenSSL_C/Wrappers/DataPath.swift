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

// FIXME: ###, do most of this in C

final class DataPath {
    private let mode: UnsafeMutablePointer<dp_mode_t>

    private let encBuffer: UnsafeMutablePointer<zeroing_data_t>

    private let decBuffer: UnsafeMutablePointer<zeroing_data_t>

    private let resizeStep: Int

    private let maxPacketId: UInt32

    private var outPacketId: UInt32

    init(mode: UnsafeMutablePointer<dp_mode_t>, peerId: UInt32) {
        self.mode = mode
        dp_mode_set_peer_id(mode, peerId)

        let oneKilo = 1024
        encBuffer = zd_create(64 * oneKilo)
        decBuffer = zd_create(64 * oneKilo)
        resizeStep = 1024
        maxPacketId = .max - 10 * UInt32(oneKilo)
        outPacketId = .zero

        // FIXME: ###, replay protection
//        if (usesReplayProtection) {
//            self.inReplay = [[ReplayProtector alloc] init];
//        }
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

// MARK: - Compound

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
    ) throws -> (UInt32, Data) {
        let buf = withNewBuffer ? zd_create(0) : nil
        return try decryptAndParse(packet, buf: buf)
    }

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
            return Data(bytes: zd.pointee.bytes, count: zd.pointee.length)
        }
    }

    func decryptAndParse(
        _ packet: Data,
        buf: UnsafeMutablePointer<zeroing_data_t>?
    ) throws -> (UInt32, Data) {
        let buf = buf ?? decBuffer
        resize(buf, for: packet.count)
        return try packet.withUnsafeBytes { src in
            var packetId: UInt32 = .zero
            var error = dp_error_t()
            let zd = dp_mode_decrypt_and_parse(
                mode,
                buf,
                &packetId,
                src.bytePointer,
                packet.count,
                &error
            )
            guard let zd else {
                throw DataPathError(error) ?? .generic
            }
            let data = Data(bytes: zd.pointee.bytes, count: zd.pointee.length)
            return (packetId, data)
        }
    }
}

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

// MARK: - Split

extension DataPath {
    func assemble(packetId: UInt32, payload: Data) -> Data {
        let inputCount = payload.count
        let output = zd_create(dp_mode_assemble_capacity(mode, inputCount))
        defer {
            zd_free(output)
        }
        return payload.withUnsafeBytes { input in
            let outputLength = dp_mode_assemble(
                mode,
                packetId,
                output,
                input.bytePointer,
                inputCount
            )
            return Data(bytes: output.pointee.bytes, count: outputLength)
        }
    }

    func encrypt(key: UInt8, packetId: UInt32, assembled: Data) throws -> Data {
        let inputCount = assembled.count
        let output = zd_create(dp_mode_encrypt_capacity(mode, inputCount))
        defer {
            zd_free(output)
        }
        return try assembled.withUnsafeBytes { input in
            var error = dp_error_t()
            let outputLength = dp_mode_encrypt(
                mode,
                key,
                packetId,
                output,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outputLength > 0 else {
                throw DataPathError(error) ?? .generic
            }
            return Data(bytes: output.pointee.bytes, count: outputLength)
        }
    }

    func decrypt(packet: Data) throws -> (UInt32, Data) {
        let inputCount = packet.count
        let output = zd_create(inputCount)
        defer {
            zd_free(output)
        }
        return try packet.withUnsafeBytes { input in
            var packetId: UInt32 = 0
            var error = dp_error_t()
            let outputLength = dp_mode_decrypt(
                mode,
                output,
                &packetId,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outputLength > 0 else {
                throw DataPathError(error) ?? .generic
            }
            let data = Data(bytes: output.pointee.bytes, count: outputLength)
            return (packetId, data)
        }
    }

    func parse(decryptedPacket: Data) throws -> Data {
        var inputCopy = [UInt8](decryptedPacket) // FIXME: ###, copy because parsed in place
        let inputCount = inputCopy.count
        let output = zd_create(inputCount)
        defer {
            zd_free(output)
        }
        return try inputCopy.withUnsafeMutableBytes { input in
            var header: UInt8 = 0
            var error = dp_error_t()
            let outputLength = dp_mode_parse(
                mode,
                output,
                &header,
                input.bytePointer,
                inputCount,
                &error
            )
            guard outputLength > 0 else {
                throw DataPathError(error) ?? .generic
            }
            return Data(bytes: output.pointee.bytes, count: outputLength)
        }
    }
}
