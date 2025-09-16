// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension ControlChannel {
    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        authKey key: OpenVPN.StaticKey,
        digest: OpenVPN.Digest
    ) throws {
        self.init(ctx, prng: prng, serializer: try AuthSerializer(ctx, digest: digest, key: key))
    }

    convenience init(
        _ ctx: PartoutLoggerContext,
        prng: PRNGProtocol,
        cryptKey key: OpenVPN.StaticKey
    ) throws {
        self.init(ctx, prng: prng, serializer: try CryptSerializer(ctx, key: key))
    }
}
