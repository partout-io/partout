// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {

    /// A set of credentials for authentication.
    public struct Credentials: Hashable, Sendable {
        public enum OTPMethod: Hashable, Codable, Sendable {
            case none

            case append

            case encode
        }

        /// The username.
        public let username: String

        /// The password.
        public let password: String

        /// The OTP method (defaults to ``OTPMethod-swift.enum/none``).
        public let otpMethod: OTPMethod

        /// The OTP.
        public let otp: String?

        fileprivate init(username: String, password: String, otpMethod: OTPMethod, otp: String?) {
            self.username = username
            self.password = password
            self.otpMethod = otpMethod
            self.otp = otp
        }

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
            try builder()
                .buildForAuthentication()
        }
    }
}

extension OpenVPN.Credentials: Codable {
    enum CodingKeys: CodingKey {
        case username

        case password

        case otp

        case otpMethod
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
    public struct Builder: Hashable {
        public var username: String

        public var password: String

        public var otpMethod: OTPMethod

        public var otp: String?

        public init(
            username: String = "",
            password: String = "",
            otpMethod: OTPMethod = .none,
            otp: String? = nil
        ) {
            self.username = username
            self.password = password
            self.otpMethod = otpMethod
            self.otp = otp
        }

        public func build() -> OpenVPN.Credentials {
            OpenVPN.Credentials(
                username: username,
                password: password,
                otpMethod: otpMethod,
                otp: otp
            )
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
                throw PartoutError(.OpenVPN.otpRequired)
            }
            return password + otp

        case .encode:
            guard let otp else {
                throw PartoutError(.OpenVPN.otpRequired)
            }
            let base64Password = password.data(using: .utf8)?.base64EncodedString() ?? ""
            let base64OTP = otp.data(using: .utf8)?.base64EncodedString() ?? ""
            return "SCRV1:\(base64Password):\(base64OTP)"
        }
    }
}
