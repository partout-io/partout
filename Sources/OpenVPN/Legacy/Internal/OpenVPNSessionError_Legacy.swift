// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
internal import _PartoutOpenVPNLegacy_ObjC
#endif
import Foundation

/// Thrown during `OpenVPNSession` operation.
enum OpenVPNSessionError: Error {

    /// Recoverable error (reconnecting may resolve).
    case recoverable(_ error: Error?)

    /// The negotiation timed out.
    case negotiationTimeout

    /// The VPN session id is missing.
    case missingSessionId

    /// The VPN session id doesn't match.
    case sessionMismatch

    /// The connection key is wrong or wasn't expected.
    case badKey

    /// Control channel failure.
    case controlChannel(message: String)

    /// The control packet has an incorrect prefix payload.
    case wrongControlDataPrefix

    /// The provided credentials failed authentication.
    case badCredentials

    /// The provided credentials failed authentication, but should retry without local options.
    case badCredentialsWithLocalOptions

    /// The reply to PUSH_REQUEST is malformed.
    case malformedPushReply

    /// A write operation took too long.
    case writeTimeout

    /// The server couldn't ping back before timeout.
    case pingTimeout

    /// The session reached a stale state and can't be recovered.
    case staleSession

    /// Server uses compression.
    case serverCompression

    /// Missing routing information.
    case noRouting

    /// Remote server shut down (--explicit-exit-notify).
    case serverShutdown

    /// Programming errors.
    case assertion

    /// NSError from the Objective-C layer, see `CPartoutOpenVPN`.
    case native(code: OpenVPNErrorCode)
}

extension Error {
    var asNativeOpenVPNError: OpenVPNSessionError? {
        let nativeError = self as NSError
        guard nativeError.domain == OpenVPNErrorDomain, let code = OpenVPNErrorCode(rawValue: nativeError.code) else {
            return nil
        }
        return .native(code: code)
    }
}
