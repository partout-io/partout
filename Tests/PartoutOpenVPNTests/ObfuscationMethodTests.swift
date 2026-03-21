// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
@testable import PartoutOpenVPN
import Testing

struct ObfuscationMethodTests {
    @Test
    func givenXormask_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.xormask(mask: SecureData(Data([1, 2, 3]))))
    }

    @Test
    func givenXorptrpos_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.xorptrpos)
    }

    @Test
    func givenReverse_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.reverse)
    }

    @Test
    func givenObfuscate_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.obfuscate(mask: SecureData(Data([1, 2, 3]))))
    }

    @Test
    func givenTaggedXormaskPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"type":"xormask","mask":"AQID"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .xormask(mask: SecureData(Data([1, 2, 3]))))
    }

    @Test
    func givenTaggedXorptrposPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"type":"xorptrpos"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .xorptrpos)
    }

    @Test
    func givenTaggedReversePayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"type":"reverse"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .reverse)
    }

    @Test
    func givenTaggedObfuscatePayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"type":"obfuscate","mask":"AQID"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .obfuscate(mask: SecureData(Data([1, 2, 3]))))
    }

    @Test
    func givenLegacyXormaskPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"xormask":{"mask":"AQID"}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .xormask(mask: SecureData(Data([1, 2, 3]))))
    }

    @Test
    func givenLegacyXorptrposPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"xorptrpos":{}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .xorptrpos)
    }

    @Test
    func givenLegacyReversePayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"reverse":{}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .reverse)
    }

    @Test
    func givenLegacyObfuscatePayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"obfuscate":{"mask":"AQID"}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        #expect(decoded == .obfuscate(mask: SecureData(Data([1, 2, 3]))))
    }

    @Test
    func givenMalformedTaggedXormaskPayload_whenDecode_thenFailsWithoutLegacyFallback() {
        let data = #"{"type":"xormask"}"#.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        }
    }

    @Test
    func givenMalformedLegacyXormaskPayload_whenDecode_thenFailsWithoutTryingOtherLegacyCases() {
        let data = #"{"xormask":{}}"#.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        }
    }

    @Test
    func givenMalformedTaggedObfuscatePayload_whenDecode_thenFailsWithoutLegacyFallback() {
        let data = #"{"type":"obfuscate"}"#.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        }
    }

    @Test
    func givenMalformedLegacyObfuscatePayload_whenDecode_thenFailsWithoutTryingOtherLegacyCases() {
        let data = #"{"obfuscate":{}}"#.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: data)
        }
    }
}

private extension ObfuscationMethodTests {
    func assertRoundTrip(_ value: OpenVPN.ObfuscationMethod) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(OpenVPN.ObfuscationMethod.self, from: encoded)
        #expect(decoded == value)
    }
}
