// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

public final class NativeTunnel: TunnelProtocol, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let ref: UnsafeMutableRawPointer?

    public init(
        _ ctx: PartoutLoggerContext,
        ref: UnsafeMutableRawPointer?
    ) {
        self.ctx = ctx
        self.ref = ref
    }

    public func prepare(purge: Bool) async throws {
        // FIXME: #1656, Implement in pp_tun_strg
//        fatalError()
    }

    public func install(_ profile: Profile, connect: Bool, options: (any Sendable)?, title: @escaping (Profile) -> String) async throws {
        let encoder = JSONEncoder.shared()
        let profileJSON = try encoder.encodeJSON(profile.asTaggedProfile)
        let optionsJSON: String? = (options as? Encodable)
            .map {
                do {
                    return try encoder.encodeJSON($0)
                } catch {
                    pp_log(ctx, .core, .error, "Unable to encode install options: \(error)")
                    return nil
                }
            } ?? nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = NativeCompletion(continuation: continuation)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            profileJSON.withCString { profile in
                if let optionsJSON {
                    optionsJSON.withCString { options in
                        pp_tun_strg_install(
                            ref, profile, connect, options,
                            ctx, NativeCompletion.callback
                        )
                    }
                } else {
                    pp_tun_strg_install(
                        ref, profile, connect, nil,
                        ctx, NativeCompletion.callback
                    )
                }
            }
        }
    }

    public func uninstall(profileId: Profile.ID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = NativeCompletion(continuation: continuation)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            profileId.uuidString.withCString {
                pp_tun_strg_uninstall(ref, $0, ctx, NativeCompletion.callback)
            }
        }
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = NativeCompletion(continuation: continuation)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            profileId.uuidString.withCString {
                pp_tun_strg_disconnect(ref, $0, ctx, NativeCompletion.callback)
            }
        }
    }

    public func sendMessage(_ message: Data, to profileId: Profile.ID) async throws -> Data? {
        // FIXME: #1656, Implement in pp_tun_strg
//        fatalError()
        nil
    }

    public var snapshots: [Profile.ID: TunnelSnapshot] {
        // FIXME: #1656, Implement in pp_tun_strg
//        fatalError()
        [:]
    }

    public var snapshotsStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        // FIXME: #1656, Implement in pp_tun_strg
//        fatalError()
        AsyncStream { nil }
    }

    public func allEnvironments() async -> [Profile.ID: TunnelEnvironmentReader] {
        // FIXME: #1656, Implement in pp_tun_strg
//        fatalError()
        [:]
    }

    public func environment(for profileId: Profile.ID) async -> TunnelEnvironmentReader? {
        // FIXME: #1656, Implement in pp_tun_strg
//        fatalError()
        nil
    }
}
