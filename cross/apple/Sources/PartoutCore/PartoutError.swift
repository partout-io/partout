// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Extensible error type thrown by the library.
public struct PartoutError: Error {
    private static let subCodeKey = "subCode"

    public let code: Code

    public let reason: Error?

    /// Native context for validation and module errors; never serialized into an ABI envelope.
    public enum Context: Sendable {
        case incompatibleModules([Module])
        case incompleteModule(any ModuleBuilder)
        case invalidField(ModuleField)
    }

    public let context: Context?

    /// Portable JSON context received from or sent to the native runtime.
    public let payload: JSON?

    public init(_ code: Code, context: Context? = nil, payload: JSON? = nil, reason: Error? = nil) {
        self.code = code
        self.context = context
        self.payload = payload
        self.reason = reason
    }

    public init?(rawValue: String) {
        guard let errorPair = PartoutErrorPair(rawValue: rawValue) else { return nil }
        self.init(errorPair.code, payload: errorPair.subCode.map {
            [Self.subCodeKey: .string($0)]
        })
    }

    public var subCode: String? {
        payload?[Self.subCodeKey]?.stringValue
    }

    public var errorPair: PartoutErrorPair {
        PartoutErrorPair(code: code, subCode: subCode)
    }

    public var rawValue: String { errorPair.rawValue }

    public init(codeForOpenVPN code: OpenVPNErrorCode) {
        self.init(.openVPN, payload: [Self.subCodeKey: .string(code.rawValue)])
    }

    public init(codeForWireGuard code: WireGuardErrorCode) {
        self.init(.wireGuard, payload: [Self.subCodeKey: .string(code.rawValue)])
    }

    public init(_ code: Code, _ reason: Error) {
        self.init(code, reason: reason)
    }

    public init(_ error: Error) {
        switch error {
        case let error as Self:
            self = error
        default:
            self = Self.unhandled(reason: error)
        }
    }
}

extension PartoutError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code
    }
}

extension Error {
    public var partoutErrorCode: PartoutError.Code {
        switch self {
        case let pe as PartoutError:
            return pe.code
        default:
            return .unhandled
        }
    }
}

// MARK: - Description

extension PartoutError: CustomDebugStringConvertible {
    public var debugDescription: String {
        var desc: [String] = ["PartoutError.\(code.rawValue)"]
        if let context {
            desc.append("context=\(String(describing: context))")
        }
        if let payload {
            desc.append("payload=\(payload.debugDescription)")
        }
        if let reason {
            desc.append("reason=\(reason) (\(reason.localizedDescription))")
        }
        return "{\(desc.joined(separator: ", "))}"
    }
}
