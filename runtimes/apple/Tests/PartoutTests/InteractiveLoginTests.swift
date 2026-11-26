// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct InteractiveLoginTests {
    @Test(arguments: [OpenVPN.Credentials.OTPMethod.none, .append, .encode])
    func preparesOpenVPNWithoutChangingOriginal(method: OpenVPN.Credentials.OTPMethod) throws {
        var configuration = OpenVPN.Configuration.Builder()
        configuration.ca = OpenVPN.CryptoContainer(pem: "ca")
        configuration.remotes = [try ExtendedEndpoint("vpn.example.com", EndpointProtocol(.udp, 1194))]
        let module = try OpenVPNModule.Builder(
            configurationBuilder: configuration,
            credentials: OpenVPN.Credentials(username: "saved", password: "secret", otpMethod: method),
            isInteractive: true
        ).build()
        let profile = try Profile.Builder(modules: [module], activatingModules: true).build()

        let prepared = try profile.withInteractiveLogin(username: "entered", password: "new-secret", otp: "123456")
        let updated = try #require(prepared.modules.first as? OpenVPNModule)
        #expect(updated.credentials?.username == "entered")
        #expect(updated.credentials?.password == (method == .none ? "new-secret" : "secret"))
        #expect(updated.credentials?.otp == (method == .none ? nil : "123456"))
        #expect(updated.credentials?.otpMethod == method)
        #expect((profile.modules.first as? OpenVPNModule)?.credentials?.password == "secret")
        #expect((profile.modules.first as? OpenVPNModule)?.credentials?.otp == nil)
    }

    @Test
    func delegatesToFirstActiveInteractiveModule() throws {
        let inactive = InteractiveTestModule()
        let first = InteractiveTestModule()
        let second = InteractiveTestModule()
        let profile = try Profile.Builder(
            modules: [inactive, first, second], activeModulesIds: [first.id, second.id]
        ).build()
        let prepared = try profile.withInteractiveLogin(username: "user", password: "secret")
        let modules = prepared.modules.compactMap { $0 as? InteractiveTestModule }
        #expect(modules[0].password == nil)
        #expect(modules[1].password == "secret")
        #expect(modules[2].password == nil)
        #expect((profile.modules[1] as? InteractiveTestModule)?.password == nil)
    }

    @Test
    func noninteractiveModuleIsUnchanged() throws {
        let module: Module = IPModule.Builder().build()
        let prepared = try module.withInteractiveLogin(username: "user", password: "secret", otp: nil)
        #expect(prepared as? IPModule == module as? IPModule)
        let profile = try Profile.Builder(modules: [module], activatingModules: true).build()
        #expect(try profile.withInteractiveLogin(username: "user", password: "secret") == profile)
    }
}

private struct InteractiveTestModule: Module {
    let id = UniqueID()
    let isInteractive = true
    let isMutuallyExclusive = false
    var password: String?

    func withInteractiveLogin(username: String, password: String, otp: String?) throws -> Module {
        var copy = self
        copy.password = password
        return copy
    }
}
