// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

// FIXME: #1656, Forward pp_tun_strg
public final class NativeTunnel: TunnelProtocol, @unchecked Sendable {
    nonisolated(unsafe)
    private let ref: UnsafeMutableRawPointer?

    public init(ref: UnsafeMutableRawPointer?) {
        self.ref = ref
    }

    public func prepare(purge: Bool) async throws {
//        fatalError()
    }

    public func install(_ profile: Profile, connect: Bool, options: (any Sendable)?, title: @escaping (Profile) -> String) async throws {
        let profileJSON = try Self.encode(profile)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = NativeCompletion(continuation: continuation)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            // FIXME: #1656, Ignore options
            profileJSON.withCString {
                pp_tun_strg_install(ref, $0, connect, nil, ctx, NativeCompletion.callback)
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
//        fatalError()
        nil
    }

    public var snapshots: [Profile.ID: TunnelSnapshot] {
//        fatalError()
        [:]
    }

    public var snapshotsStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
//        fatalError()
        AsyncStream { nil }
    }

    public func allEnvironments() async -> [Profile.ID: TunnelEnvironmentReader] {
//        fatalError()
        [:]
    }

    public func environment(for profileId: Profile.ID) async -> TunnelEnvironmentReader? {
//        fatalError()
        nil
    }
}

private extension NativeTunnel {
    static func encode(_ profile: Profile) throws -> String {
        let data = try JSONEncoder().encode(profile.asTaggedProfile)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PartoutError(.encoding)
        }
        return json
    }
}
