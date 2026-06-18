// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ControlChannelV3 {
    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        authKey key: OpenVPN.StaticKey,
        digest: OpenVPN.Digest
    ) throws {
        self.init(ctx, prng: prng, serializer: try ControlChannel.AuthSerializer(ctx, digest: digest, key: key))
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        cryptKey key: OpenVPN.StaticKey
    ) throws {
        self.init(ctx, prng: prng, serializer: try ControlChannel.CryptSerializer(ctx, key: key))
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        cryptV2Key key: OpenVPN.StaticKey,
        wrappedKey: SecureData
    ) throws {
        self.init(
            ctx,
            prng: prng,
            serializer: try ControlChannel.CryptV2Serializer(ctx, key: key, wrappedKey: wrappedKey)
        )
    }
}
