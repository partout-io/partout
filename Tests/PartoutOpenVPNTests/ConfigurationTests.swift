// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPNConnection
import Testing

struct ConfigurationTests {
    @Test
    func givenRandomizeHostnames_whenProcessRemotes_thenHostnamesHaveAlphanumericPrefix() throws {
        var builder = OpenVPN.Configuration.Builder()
        let hostname = "my.host.name"
        let ipv4 = "1.2.3.4"
        builder.remotes = [
            try? ExtendedEndpoint(hostname, .init(.udp, 1111)),
            try? ExtendedEndpoint(ipv4, .init(.udp4, 3333))
        ].compactMap { $0 }
        builder.randomizeHostnames = true
        let cfg = try builder.build(isClient: false)

        try cfg.processedRemotes(prng: MockPRNG())?
            .forEach {
                let comps = $0.address.rawValue.components(separatedBy: ".")
                let first = try #require(comps.first)
                if $0.isHostname {
                    #expect($0.address.rawValue.hasSuffix(hostname))
                    #expect(first.count == 12)
                    #expect(first.allSatisfy("0123456789abcdef".contains))
                } else {
                    #expect($0.address.rawValue == ipv4)
                }
            }
    }

    @Test
    func givenDataCiphersAndFallback_whenBuildingNegotiableDataCiphers_thenAppendsFallbackCipher() throws {
        var builder = OpenVPN.Configuration.Builder()
        builder.cipher = .aes128cbc
        builder.dataCiphers = [.aes256gcm, .aes128gcm]
        let cfg = try builder.build(isClient: false)

        #expect(cfg.negotiableDataCiphers == [.aes256gcm, .aes128gcm, .aes128cbc])
    }

    @Test
    func givenServerCipher_whenNegotiatingDataChannel_thenUsesServerCipher() throws {
        var localBuilder = OpenVPN.Configuration.Builder()
        localBuilder.cipher = .aes128cbc
        localBuilder.dataCiphers = [.aes256gcm, .aes128gcm]
        let local = try localBuilder.build(isClient: false)

        var pushedBuilder = OpenVPN.Configuration.Builder()
        pushedBuilder.cipher = .aes128gcm
        let pushed = try pushedBuilder.build(isClient: false)

        #expect(local.negotiatedDataChannelCipher(with: pushed, serverOptions: nil) == .aes128gcm)
    }

    @Test
    func givenServerOptionsCipherInNegotiableList_whenNegotiatingDataChannel_thenUsesServerCipher() throws {
        var localBuilder = OpenVPN.Configuration.Builder()
        localBuilder.cipher = .aes128cbc
        localBuilder.dataCiphers = [.aes256gcm, .aes128gcm]
        let local = try localBuilder.build(isClient: false)

        let pushed = try OpenVPN.Configuration.Builder().build(isClient: false)

        var serverBuilder = OpenVPN.Configuration.Builder()
        serverBuilder.cipher = .aes128gcm
        let server = try serverBuilder.build(isClient: false)

        #expect(local.negotiatedDataChannelCipher(with: pushed, serverOptions: server) == .aes128gcm)
    }

    @Test
    func givenNoServerCipher_whenNegotiatingDataChannel_thenUsesFallbackCipher() throws {
        var localBuilder = OpenVPN.Configuration.Builder()
        localBuilder.cipher = .aes256cbc
        let local = try localBuilder.build(isClient: false)

        let pushed = try OpenVPN.Configuration.Builder().build(isClient: false)

        #expect(local.negotiatedDataChannelCipher(with: pushed, serverOptions: nil) == .aes256cbc)
    }
}

private final class MockPRNG: PRNGProtocol {
    func uint32() -> UInt32 {
        1
    }

    func data(length: Int) -> Data {
        Data(Array(repeating: 1, count: length))
    }

    func safeData(length: Int) -> SecureData {
        SecureData(data(length: length))
    }
}
