// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

package io.partout

import io.partout.extensions.effectiveDNSModule
import io.partout.models.DNSModule
import io.partout.models.DNSModuleProtocolTypecleartext
import io.partout.models.DNSModuleProtocolTypehttps

object DNSSettingsTest {
    @JvmStatic
    fun main(args: Array<String>) {
        val vpn = DNSModule(
            id = "vpn",
            protocolType = DNSModuleProtocolTypecleartext(),
            servers = listOf("10.0.0.1"),
            domainName = "vpn.example",
            searchDomains = listOf("vpn.example")
        )
        val profile = vpn.copy(
            id = "profile",
            servers = listOf("1.1.1.1"),
            domainName = "profile.example",
            searchDomains = listOf("profile.example")
        )
        check(listOf(vpn, profile).effectiveDNSModule() == profile)
        check(listOf(profile, vpn).effectiveDNSModule() == vpn)
        val inheriting = profile.copy(inheritsVPN = true)
        val inherited = checkNotNull(listOf(vpn, inheriting).effectiveDNSModule())
        check(inherited.servers == vpn.servers)
        check(inherited.protocolType === vpn.protocolType)
        check(inherited.domainName == vpn.domainName)
        check(inherited.searchDomains == vpn.searchDomains)
        check(listOf(inheriting).effectiveDNSModule() == inheriting)
        val empty = profile.copy(servers = emptyList())
        check(listOf(vpn, empty).effectiveDNSModule() == vpn)
        check(listOf(empty).effectiveDNSModule() == null)
        check(emptyList<DNSModule>().effectiveDNSModule() == null)
        val encrypted = profile.copy(
            protocolType = DNSModuleProtocolTypehttps("https://dns.example/dns-query"),
            servers = emptyList()
        )
        check(listOf(vpn, encrypted).effectiveDNSModule() == encrypted)
        check(listOf(encrypted, inheriting).effectiveDNSModule()?.protocolType === encrypted.protocolType)
        check(listOf(vpn, profile, inheriting).effectiveDNSModule()?.servers == profile.servers)
        println("DNS replacement and inheritance passed")
    }
}
