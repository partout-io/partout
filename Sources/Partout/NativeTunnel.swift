// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

public final class NativeTunnel: TunnelProtocol, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private let ref: UnsafeMutableRawPointer?

    private let snapshotsSubject: CurrentValueStream<[Profile.ID: TunnelSnapshot]>

    public init(
        _ ctx: PartoutLoggerContext,
        ref: UnsafeMutableRawPointer?
    ) {
        self.ctx = ctx
        self.ref = ref
        snapshotsSubject = CurrentValueStream([:])
    }

    public func prepare(purge: Bool) async throws {
        pp_tun_strg_prepare(
            ref,
            Unmanaged.passUnretained(self).toOpaque(),
            Self.snapshotsCallback
        )
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
        // FIXME: #188, Implement in pp_tun_strg
//        fatalError()
        nil
    }

    public var snapshots: [Profile.ID: TunnelSnapshot] {
        snapshotsSubject.value
    }

    public var snapshotsStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        snapshotsSubject.subscribe()
    }

    public func allEnvironments() async -> [Profile.ID: TunnelEnvironmentReader] {
        // FIXME: #188, Implement in pp_tun_strg
//        fatalError()
        [:]
    }

    public func environment(for profileId: Profile.ID) async -> TunnelEnvironmentReader? {
        // FIXME: #188, Implement in pp_tun_strg
//        fatalError()
        nil
    }
}

private extension NativeTunnel {
    static let snapshotsCallback: pp_tun_strg_snapshots_cb = { ctx, cJSON in
        let tunnel = Unmanaged<NativeTunnel>.fromOpaque(ctx).takeUnretainedValue()
        tunnel.submitSnapshots(String(cString: cJSON))
    }

    func submitSnapshots(_ json: String) {
        pp_log(ctx, .core, .debug, "Submit manual snapshots: \(json)")
        do {
            let data = Data(json.utf8)
            let decoded = try JSONDecoder.shared().decode([String: TunnelSnapshot].self, from: data)
            let snapshots: [Profile.ID: TunnelSnapshot] = decoded.reduce(into: [:]) {
                guard let id = Profile.ID(uuidString: $1.key) else { return }
                $0[id] = $1.value
            }
            snapshotsSubject.send(snapshots)
        } catch {
            pp_log(ctx, .core, .error, "Unable to decode snapshots: \(error)")
        }
    }
}
