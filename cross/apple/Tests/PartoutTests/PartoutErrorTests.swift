// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct PartoutErrorTests {
    @Test
    func givenNativeContext_whenWrap_thenPreservesContextAndReason() {
        let field = PartoutError.ModuleField.DNS.ipDomains
        let error: Error = PartoutError(.invalidField, context: .invalidField(field), reason: SomeDescriptiveError())
        let wrapped = PartoutError(error)
        guard case .invalidField(let wrappedField) = wrapped.context else {
            Issue.record("Expected native field context")
            return
        }
        #expect(wrappedField == field)
        #expect(ABIEnvelope(wrapped).payload == nil)
        #expect(wrapped.reason is SomeDescriptiveError)
        #expect(wrapped.payload == nil)
    }

    @Test
    func givenContextAndPayload_whenEncode_thenOnlySerializesPayload() throws {
        let field = PartoutError.ModuleField.DNS.ipDomains
        let error = PartoutError(
            .invalidField,
            context: .invalidField(field),
            payload: ["field": .string(field.key)]
        )
        let wrapped = PartoutError(error as Error)
        guard case .invalidField(let wrappedField) = wrapped.context else {
            Issue.record("Expected native field context")
            return
        }
        #expect(wrappedField == field)
        let envelope = ABIEnvelope(wrapped)
        let json = try JSON(encodable: envelope)
        #expect(json == ["code": "invalidField", "payload": ["field": .string(field.key)]])
    }

    @Test(arguments: [JSON.null, ["subCode": "tlsFailure", "arguments": ["detail"]]])
    func givenPayloadAndReason_whenWrap_thenPreservesEnvelope(payload: JSON) {
        let error: Error = PartoutError(.openVPN, payload: payload, reason: SomeDescriptiveError())
        let wrapped = PartoutError(error)
        #expect(wrapped.reason is SomeDescriptiveError)
        #expect(wrapped.payload == payload)
        #expect(ABIEnvelope(wrapped).payload == payload)
    }


    @Test(arguments: ["timeout", "openVPN.tlsFailure", "wireGuard.peerHasInvalidPublicKey", "openVPN.future.code"])
    func givenRuntimeCode_whenParse_thenRoundTrips(raw: String) throws {
        let extended = try #require(PartoutErrorExtendedCode(rawValue: raw))
        #expect(extended.rawValue == raw)
        let error = try #require(PartoutError(rawValue: raw))
        #expect(error.code == extended.code)
        #expect(error.subCode == extended.subCode)
        #expect(error.rawValue == raw)
    }

    @Test(arguments: ["", "unknown.subcode", "openVPN."])
    func givenInvalidRuntimeCode_whenParse_thenFails(raw: String) {
        #expect(PartoutErrorExtendedCode(rawValue: raw) == nil)
    }

    @Test(arguments: [
        (PartoutError(codeForOpenVPN: .otpRequired), PartoutErrorCode.openVPN, "otpRequired"),
        (PartoutError(codeForWireGuard: .emptyPeers), PartoutErrorCode.wireGuard, "emptyPeers")
    ])
    func givenProtocolError_whenEncodeEnvelope_thenPreservesCodeAndPayload(
        error: PartoutError,
        code: PartoutErrorCode,
        subCode: String
    ) throws {
        let envelope = ABIEnvelope(error)
        let encoded = try JSONEncoder.shared().encode(envelope)
        let json = try JSONDecoder.shared().decode(JSON.self, from: encoded)
        #expect(json == ["code": .string(code.rawValue), "payload": ["subCode": .string(subCode)]])

        let wrapped = PartoutError(error)
        #expect(wrapped.code == code)
        #expect(error.partoutErrorCode == code)
        #expect(ABIEnvelope(wrapped).payload == envelope.payload)
    }

    @Test(arguments: [OpenVPN.Credentials.OTPMethod.append, .encode])
    func givenMissingOTP_whenAuthenticate_thenThrowsProtocolError(method: OpenVPN.Credentials.OTPMethod) {
        let credentials = OpenVPN.Credentials.Builder(username: "user", password: "password", otpMethod: method)
        #expect {
            _ = try credentials.buildForAuthentication()
        } throws: { error in
            guard let error = error as? PartoutError else { return false }
            return error.code == .openVPN && error.payload == ["subCode": "otpRequired"]
        }
    }

    @Test
    func givenError_whenWrap_thenReturnsUnhandled() {
        do {
            throw SomeUnmappableError()
        } catch {
            let sut = PartoutError(error)
            #expect(sut == .unhandled(reason: error))
        }
    }

    @Test
    func givenErrorWithoutPayload_whenWrap_thenPreservesCode() {
        let error: Error = PartoutError(.decoding)
        let sut = PartoutError(error)
        #expect(sut.code == .decoding)
        #expect(sut.context == nil)
        #expect(sut.payload == nil)
        #expect(sut.reason == nil)
        #expect(error.partoutErrorCode == .decoding)
    }

    @Test(arguments: [
        (PartoutError(.authentication), "{PartoutError.authentication}"),
        (PartoutError(.authentication, payload: .null), "{PartoutError.authentication, payload=null}"),
        (PartoutError(.authentication, payload: .null, reason: SomeDescriptiveError()), "{PartoutError.authentication, payload=null, reason=SomeDescriptiveError() (errorDescription)}")
    ])
    func givenError_whenDescribe_thenReturnsDescription(error: PartoutError, expectedDescription: String) {
        #expect(error.debugDescription == expectedDescription)
    }
}

private extension PartoutErrorTests {
    struct SomeUnmappableError: Error {
    }

    struct SomeDescriptiveError: Error, LocalizedError {
        var errorDescription: String? {
            "errorDescription"
        }
    }
}
