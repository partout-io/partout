// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import PartoutOpenVPN
import Testing

struct ConfigurationBuilderTests {
    @Test
    func givenBuilder_whenClient_thenHasFallbackValues() throws {
        var sut = OpenVPN.Configuration.Builder()
        sut.ca = .init(pem: "")
        sut.remotes = [.init(rawValue: "1.2.3.4:UDP:1000")!]
        let cfg = try sut.build(isClient: true)
        #expect(cfg.cipher == .aes128cbc)
        #expect(cfg.digest == nil)
        #expect(cfg.compressionFraming == nil)
        #expect(cfg.compressionAlgorithm == nil)
    }

    @Test
    func givenBuilder_whenNonClient_thenHasNoFallbackValues() throws {
        let sut = OpenVPN.Configuration.Builder()
        let cfg = try sut.build(isClient: false)
        #expect(cfg.cipher == nil)
        #expect(cfg.digest == nil)
        #expect(cfg.compressionFraming == nil)
        #expect(cfg.compressionAlgorithm == nil)
    }
}
