// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct SensitiveEncoderTests {
    private let sut: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.userInfo = [.redactingSensitiveData: true]
        return encoder
    }()

    private let decoder = JSONDecoder()

    @Test
    func givenSecureData_whenEncodeSensitive_thenIsRedacted() throws {
        let data = try sut.encode(SecureData("123456"))
        #expect(throws: Error.self) {
            try decoder.decode(SecureData.self, from: data)
        }
        let string = try decoder.decode(String.self, from: data)
        #expect(string == JSONEncoder.redactedValue)
    }

    @Test
    func givenAddress_whenEncodeSensitive_thenIsRedacted() throws {
        let data = try sut.encode(Address(rawValue: "1.2.3.4"))
        #expect(throws: Error.self) {
            try decoder.decode(Address.self, from: data)
        }
        let string = try decoder.decode(String.self, from: data)
        #expect(string == JSONEncoder.redactedValue)
    }

    @Test
    func givenEndpoint_whenEncodeSensitive_thenIsRedacted() throws {
        let data = try sut.encode(Endpoint(rawValue: "1.2.3.4:12345"))
        #expect(throws: Error.self) {
            try decoder.decode(Endpoint.self, from: data)
        }
        let string = try decoder.decode(String.self, from: data)
        #expect(string == "\(JSONEncoder.redactedValue):12345")
    }

    @Test
    func givenExtendedEndpoint_whenEncodeSensitive_thenIsRedacted() throws {
        let data = try sut.encode(ExtendedEndpoint(rawValue: "1.2.3.4:UDP:12345"))
        #expect(throws: Error.self) {
            try decoder.decode(ExtendedEndpoint.self, from: data)
        }
        let string = try decoder.decode(String.self, from: data)
        #expect(string == "\(JSONEncoder.redactedValue):UDP:12345")
    }

    @Test
    func givenSubnet_whenEncodeSensitive_thenIsRedacted() throws {
        let data = try sut.encode(Subnet(rawValue: "1.2.3.4/16"))
        #expect(throws: Error.self) {
            try decoder.decode(Subnet.self, from: data)
        }
        let string = try decoder.decode(String.self, from: data)
        #expect(string == "\(JSONEncoder.redactedValue)/16")
    }

    @Test
    func givenEncodable_whenJSON_thenReturnsJSON() throws {
        let encodable = SomeEncodable(foo: 123, secureBar: "hello")
        #expect(encodable.asJSON(.global, withSensitiveData: true, sortingKeys: true) == "{\"foo\":123,\"secureBar\":\"hello\"}")
        #expect(encodable.asJSON(.global, withSensitiveData: false, sortingKeys: true) == "{\"foo\":123,\"secureBar\":\"\(JSONEncoder.redactedValue)\"}")
    }
}

private struct SomeEncodable: Encodable {
    enum CodingKeys: CodingKey {
        case foo

        case secureBar
    }

    var foo: Int

    var secureBar: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(foo, forKey: .foo)
        if encoder.shouldEncodeSensitiveData {
            try container.encode(secureBar, forKey: .secureBar)
        } else {
            try container.encode(JSONEncoder.redactedValue, forKey: .secureBar)
        }
    }
}
