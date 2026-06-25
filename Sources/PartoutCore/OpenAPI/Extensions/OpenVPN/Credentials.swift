// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN.Credentials {
    enum CodingKeys: CodingKey {
        case username
        case password
        case otp
        case otpMethod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            username: try container.decode(String.self, forKey: .username),
            password: try container.decode(String.self, forKey: .password),
            otpMethod: try container.decode(OTPMethod.self, forKey: .otpMethod),
            otp: try container.decodeIfPresent(String.self, forKey: .otp)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encoder.shouldEncodeSensitiveData ? username : PartoutLogger.redactedValue, forKey: .username)
        try container.encode(encoder.shouldEncodeSensitiveData ? password : PartoutLogger.redactedValue, forKey: .password)
        try container.encode(otpMethod, forKey: .otpMethod)
        try container.encode(encoder.shouldEncodeSensitiveData ? otp : PartoutLogger.redactedValue, forKey: .otp)
    }
}

extension OpenVPN.Credentials {
    public func builder() -> Builder {
        var builder = Builder()
        builder.username = username
        builder.password = password
        builder.otpMethod = otpMethod
        builder.otp = otp
        return builder
    }

    public var isEmpty: Bool {
        username.isEmpty && password.isEmpty
    }

    public func forAuthentication() throws -> Self {
        try builder().buildForAuthentication()
    }
}

extension OpenVPN.Credentials {
    public struct Builder: Hashable {
        public var username: String
        public var password: String
        public var otpMethod: OTPMethod
        public var otp: String?

        public init(username: String = "", password: String = "", otpMethod: OTPMethod = .none, otp: String? = nil) {
            self.username = username
            self.password = password
            self.otpMethod = otpMethod
            self.otp = otp
        }

        public func build() -> OpenVPN.Credentials {
            OpenVPN.Credentials(username: username, password: password, otpMethod: otpMethod, otp: otp)
        }

        public func buildForAuthentication() throws -> OpenVPN.Credentials {
            OpenVPN.Credentials(
                username: username,
                password: try otpMethod.encoded(with: password, otp: otp),
                otpMethod: .none,
                otp: nil
            )
        }
    }
}

private extension OpenVPN.Credentials.OTPMethod {
    func encoded(with password: String, otp: String?) throws -> String {
        switch self {
        case .none:
            return password
        case .append:
            guard let otp else {
                throw PartoutError(.openVPNOTPRequired)
            }
            return password + otp
        case .encode:
            guard let otp else {
                throw PartoutError(.openVPNOTPRequired)
            }
            let base64Password = password.data(using: .utf8)?.base64EncodedString() ?? ""
            let base64OTP = otp.data(using: .utf8)?.base64EncodedString() ?? ""
            return "SCRV1:\(base64Password):\(base64OTP)"
        }
    }
}

// MARK: - Custom Codable

extension OpenVPN.Credentials.OTPMethod {
    private enum LegacyCodingKeys: String, CodingKey {
        case none
        case append
        case encode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawValue = try? container.decode(String.self) {
            guard let method = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown OTP method '\(rawValue)'"
                )
            }
            self = method
            return
        }

        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if legacyContainer.contains(.none) {
            self = .none
        } else if legacyContainer.contains(.append) {
            self = .append
        } else if legacyContainer.contains(.encode) {
            self = .encode
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown legacy OTP method")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
