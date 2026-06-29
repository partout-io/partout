// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

extension ControlChannelV3 {
    convenience init(
        _ ctx: PartoutLoggerContext,
        fnt: pp_crypto_enc_fnt,
        prng: PRNGProtocol,
        authKey key: OpenVPN.StaticKey,
        digest: OpenVPN.Digest
    ) throws {
        self.init(
            ctx,
            prng: prng,
            serializer: try ControlChannel.AuthSerializer(ctx, fnt: fnt, digest: digest, key: key)
        )
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        fnt: pp_crypto_enc_fnt,
        prng: PRNGProtocol,
        cryptKey key: OpenVPN.StaticKey
    ) throws {
        self.init(
            ctx,
            prng: prng,
            serializer: try ControlChannel.CryptSerializer(ctx, fnt: fnt, key: key)
        )
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        fnt: pp_crypto_enc_fnt,
        prng: PRNGProtocol,
        cryptV2Key key: OpenVPN.StaticKey,
        wrappedKey: SecureData
    ) throws {
        self.init(
            ctx,
            prng: prng,
            serializer: try ControlChannel.CryptV2Serializer(ctx, fnt: fnt, key: key, wrappedKey: wrappedKey)
        )
    }
}
