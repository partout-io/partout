// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include "NetworkSettings.h"
#include "NetworkSettingsApi.h"
#include <partout/models/TunnelRemoteInfoWrapper.h>
#include <algorithm>
#include <charconv>
#include <cstdio>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <type_traits>
#include <vector>

namespace {
namespace Models = Partout::Models;
void Check(ULONG status) {
    if (status != NO_ERROR) throw std::runtime_error("Windows network error " + std::to_string(status));
}
SOCKADDR_INET Address(const std::string &text, ADDRESS_FAMILY family) {
    SOCKADDR_INET result{};
    result.si_family = family;
    void *bytes = family == AF_INET ? static_cast<void *>(&result.Ipv4.sin_addr) : &result.Ipv6.sin6_addr;
    if (InetPtonA(family, text.c_str(), bytes) != 1) throw std::invalid_argument("Invalid IP address");
    return result;
}
IP_ADDRESS_PREFIX Prefix(const std::string &text, ADDRESS_FAMILY family, bool network) {
    const auto slash = text.find('/');
    IP_ADDRESS_PREFIX result{};
    result.Prefix = Address(text.substr(0, slash), family);
    unsigned length = family == AF_INET ? 32 : 128;
    if (slash != std::string::npos) {
        const auto first = text.data() + slash + 1;
        const auto end = text.data() + text.size();
        const auto parsed = std::from_chars(first, end, length);
        if (parsed.ec != std::errc{} || parsed.ptr != end || length > (family == AF_INET ? 32u : 128u))
            throw std::invalid_argument("Invalid prefix");
    }
    result.PrefixLength = static_cast<UINT8>(length);
    if (network) {
        auto bytes = family == AF_INET ? reinterpret_cast<unsigned char *>(&result.Prefix.Ipv4.sin_addr)
                                      : reinterpret_cast<unsigned char *>(&result.Prefix.Ipv6.sin6_addr);
        const unsigned size = family == AF_INET ? 4 : 16;
        for (unsigned bit = length; bit < size * 8; ++bit) bytes[bit / 8] &= ~(1u << (7 - bit % 8));
    }
    return result;
}
std::wstring Wide(const std::string &text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.c_str(), -1, nullptr, 0);
    if (!size) throw std::invalid_argument("Invalid UTF-8");
    std::wstring result(size, L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.c_str(), -1, result.data(), size))
        throw std::invalid_argument("Invalid UTF-8");
    result.pop_back();
    return result;
}
const unsigned char *Bytes(const SOCKADDR_INET &address) {
    return address.si_family == AF_INET ? reinterpret_cast<const unsigned char *>(&address.Ipv4.sin_addr)
                                      : reinterpret_cast<const unsigned char *>(&address.Ipv6.sin6_addr);
}
bool Contains(const IP_ADDRESS_PREFIX &outer, const IP_ADDRESS_PREFIX &inner) {
    if (outer.Prefix.si_family != inner.Prefix.si_family || outer.PrefixLength > inner.PrefixLength) return false;
    for (unsigned bit = 0; bit < outer.PrefixLength; ++bit) {
        const auto mask = 1u << (7 - bit % 8);
        if ((Bytes(outer.Prefix)[bit / 8] & mask) != (Bytes(inner.Prefix)[bit / 8] & mask)) return false;
    }
    return true;
}
struct NetworkSettings {
    explicit NetworkSettings(const NetworkSettingsApi &value = {}) : api(value) {}
    NetworkSettingsApi api;
    std::mutex mutex;
    NET_LUID luid{};
    std::vector<MIB_IPFORWARD_ROW2> routes;
    std::vector<MIB_UNICASTIPADDRESS_ROW> addresses;
    std::vector<MIB_IPINTERFACE_ROW> interfaces;
    MIB_IPFORWARD_ROW2 physical4{};
    MIB_IPFORWARD_ROW2 physical6{};
    GUID guid{};
    DNS_INTERFACE_SETTINGS previousDns{};
    bool dnsSaved = false;
    bool ipv6DnsChanged = false;

    ~NetworkSettings() {
        Clear();
        if (dnsSaved) api.FreeInterfaceDnsSettings(&previousDns);
    }

    MIB_IPFORWARD_ROW2 Physical(ADDRESS_FAMILY family) {
        MIB_IPFORWARD_TABLE2 *table = nullptr;
        Check(api.GetIpForwardTable2(family, &table));
        MIB_IPFORWARD_ROW2 best{};
        ULONG64 metric = std::numeric_limits<ULONG64>::max();
        for (ULONG i = 0; i < table->NumEntries; ++i) {
            const auto &route = table->Table[i];
            if (route.DestinationPrefix.PrefixLength != 0 || route.InterfaceLuid.Value == luid.Value) continue;
            MIB_IF_ROW2 adapter{};
            adapter.InterfaceLuid = route.InterfaceLuid;
            if (api.GetIfEntry2(&adapter) || adapter.OperStatus != IfOperStatusUp || adapter.Type == IF_TYPE_SOFTWARE_LOOPBACK) continue;
            MIB_IPINTERFACE_ROW ip{};
            InitializeIpInterfaceEntry(&ip);
            ip.Family = family;
            ip.InterfaceLuid = route.InterfaceLuid;
            if (api.GetIpInterfaceEntry(&ip)) continue;
            const ULONG64 cost = static_cast<ULONG64>(route.Metric) + ip.Metric;
            if (cost < metric) {
                metric = cost;
                best = route;
            }
        }
        api.FreeMibTable(table);
        return best;
    }

    bool Clear() noexcept {
        if (ipv6DnsChanged) {
            // The controller exclusively owns a newly created Wintun adapter.
            // Its IPv6 static DNS list was empty before this transaction.
            DNS_INTERFACE_SETTINGS empty{};
            empty.Version = DNS_INTERFACE_SETTINGS_VERSION1;
            empty.Flags = DNS_SETTING_IPV6 | DNS_SETTING_NAMESERVER;
            wchar_t servers[] = L"";
            empty.NameServer = servers;
            const auto status = api.SetInterfaceDnsSettings(guid, &empty);
            if (status && status != ERROR_NOT_FOUND && status != ERROR_FILE_NOT_FOUND) {
                std::fprintf(stderr, "Wintun IPv6 DNS cleanup failed: %lu\n", status);
            } else {
                ipv6DnsChanged = false;
            }
        }
        if (dnsSaved) {
            const auto status = api.SetInterfaceDnsSettings(guid, &previousDns);
            if (status && status != ERROR_NOT_FOUND && status != ERROR_FILE_NOT_FOUND) {
                std::fprintf(stderr, "Wintun DNS cleanup failed: %lu\n", status);
            } else {
                api.FreeInterfaceDnsSettings(&previousDns);
                previousDns = {};
                dnsSaved = false;
            }
        }
        for (auto it = routes.begin(); it != routes.end();) {
            const auto status = api.DeleteIpForwardEntry2(&*it);
            if (status && status != ERROR_NOT_FOUND) {
                std::fprintf(stderr, "Wintun route cleanup failed: %lu\n", status);
                ++it;
            } else {
                it = routes.erase(it);
            }
        }
        for (auto it = addresses.begin(); it != addresses.end();) {
            const auto status = api.DeleteUnicastIpAddressEntry(&*it);
            if (status && status != ERROR_NOT_FOUND) {
                std::fprintf(stderr, "Wintun address cleanup failed: %lu\n", status);
                ++it;
            } else {
                it = addresses.erase(it);
            }
        }
        for (auto it = interfaces.begin(); it != interfaces.end();) {
            const auto status = api.SetIpInterfaceEntry(&*it);
            if (status && status != ERROR_NOT_FOUND) {
                std::fprintf(stderr, "Wintun interface cleanup failed: %lu\n", status);
                ++it;
            } else {
                it = interfaces.erase(it);
            }
        }
        const bool complete = !dnsSaved && !ipv6DnsChanged && routes.empty() && addresses.empty() && interfaces.empty();
        if (complete) luid = {};
        return complete;
    }

    void AddRoute(IP_ADDRESS_PREFIX prefix, const std::optional<std::string> &gateway, bool bypass) {
        MIB_IPFORWARD_ROW2 row{};
        InitializeIpForwardEntry(&row);
        const auto family = prefix.Prefix.si_family;
        const auto &physical = family == AF_INET ? physical4 : physical6;
        if (bypass && !physical.InterfaceLuid.Value) throw std::runtime_error("No physical route");
        row.InterfaceLuid = bypass ? physical.InterfaceLuid : luid;
        row.DestinationPrefix = prefix;
        row.NextHop.si_family = family;
        if (gateway) row.NextHop = Address(*gateway, family);
        else if (bypass) row.NextHop = physical.NextHop;
        row.Metric = 0;
        row.Protocol = MIB_IPPROTO_NETMGMT;
        routes.reserve(routes.size() + 1);
        const auto status = api.CreateIpForwardEntry2(&row);
        if (status == ERROR_OBJECT_ALREADY_EXISTS) return;
        Check(status);
        routes.push_back(row);
    }

    void ApplyIP(const Models::IPSettings &settings, ADDRESS_FAMILY family, ULONG mtu) {
        MIB_IPINTERFACE_ROW original{};
        InitializeIpInterfaceEntry(&original);
        original.InterfaceLuid = luid;
        original.Family = family;
        Check(api.GetIpInterfaceEntry(&original));
        interfaces.push_back(original);
        auto changed = original;
        changed.NlMtu = mtu;
        changed.UseAutomaticMetric = FALSE;
        changed.Metric = 1;
        changed.SitePrefixLength = 0;
        Check(api.SetIpInterfaceEntry(&changed));
        for (const auto &subnet : settings.subnets) {
            const auto prefix = Prefix(subnet, family, false);
            MIB_UNICASTIPADDRESS_ROW row{};
            InitializeUnicastIpAddressEntry(&row);
            row.InterfaceLuid = luid;
            row.Address = prefix.Prefix;
            row.OnLinkPrefixLength = prefix.PrefixLength;
            row.DadState = IpDadStatePreferred;
            addresses.reserve(addresses.size() + 1);
            const auto status = api.CreateUnicastIpAddressEntry(&row);
            if (status == ERROR_OBJECT_ALREADY_EXISTS) continue;
            Check(status);
            addresses.push_back(row);
        }
        std::vector<IP_ADDRESS_PREFIX> exclusions;
        for (const auto &route : settings.excludedRoutes) {
            const auto prefix = Prefix(route.destination.value_or(family == AF_INET ? "0.0.0.0/0" : "::/0"), family, true);
            exclusions.push_back(prefix);
            AddRoute(prefix, route.gateway, true);
        }
        for (const auto &route : settings.includedRoutes) {
            const auto prefix = Prefix(route.destination.value_or(family == AF_INET ? "0.0.0.0/0" : "::/0"), family, true);
            AddIncluded(prefix, route.gateway, exclusions);
        }
    }

    void AddIncluded(IP_ADDRESS_PREFIX prefix, const std::optional<std::string> &gateway,
                     const std::vector<IP_ADDRESS_PREFIX> &exclusions) {
        bool split = prefix.PrefixLength == 0;
        for (const auto &excluded : exclusions) {
            if (Contains(excluded, prefix)) return;
            if (Contains(prefix, excluded)) split = true;
        }
        if (!split) {
            AddRoute(prefix, gateway, false);
            return;
        }
        const unsigned bit = prefix.PrefixLength++;
        AddIncluded(prefix, gateway, exclusions);
        auto bytes = prefix.Prefix.si_family == AF_INET
                         ? reinterpret_cast<unsigned char *>(&prefix.Prefix.Ipv4.sin_addr)
                         : reinterpret_cast<unsigned char *>(&prefix.Prefix.Ipv6.sin6_addr);
        bytes[bit / 8] |= 1u << (7 - bit % 8);
        AddIncluded(prefix, gateway, exclusions);
    }

    void Apply(NET_LUID adapter, const char *json) {
        const auto info = Models::TunnelRemoteInfoWrapper::FromJson(nlohmann::json::parse(json));
        std::optional<Models::IPSettings> ipv4, ipv6;
        std::optional<Models::DNSModule> dns;
        ULONG mtu = 1420;
        auto read = [&](const Models::TaggedModule &entry) {
            if (const auto ip = std::get_if<Models::TaggedModuleIp>(&entry)) {
                if (ip->value.ipv4) ipv4 = ip->value.ipv4;
                if (ip->value.ipv6) ipv6 = ip->value.ipv6;
                if (ip->value.mtu && *ip->value.mtu) {
                    if (*ip->value.mtu < 68 || *ip->value.mtu > 65535) throw std::invalid_argument("Invalid MTU");
                    mtu = static_cast<ULONG>(*ip->value.mtu);
                }
            } else if (const auto item = std::get_if<Models::TaggedModuleDns>(&entry)) {
                dns = item->value;
            }
        };
        for (const auto &entry : info.profile.modules) {
            const auto id = std::visit([](const auto &item) -> std::string {
                if constexpr (std::is_same_v<std::decay_t<decltype(item)>, Models::TaggedModuleCustom>) {
                    return item.value.json.value("id", std::string{});
                } else {
                    return item.value.id;
                }
            }, entry);
            if (std::find(info.profile.activeModulesIds.begin(), info.profile.activeModulesIds.end(), id) == info.profile.activeModulesIds.end()) continue;
            read(entry);
            if (id == info.originalModuleId && info.modules) for (const auto &remote : *info.modules) read(remote);
        }
        if ((!ipv4 || ipv4->subnets.empty()) && (!ipv6 || ipv6->subnets.empty())) throw std::invalid_argument("No tunnel addresses");
        if (ipv6 && mtu < 1280) throw std::invalid_argument("Invalid IPv6 MTU");
        if (dns && (!std::holds_alternative<Models::DNSModuleProtocolTypeCleartext>(dns->protocolType) || dns->domainPolicy))
            throw std::invalid_argument("Encrypted or split DNS is not supported by this runtime");
        if (!Clear()) throw std::runtime_error("Previous network settings could not be removed");
        luid = adapter;
        physical4 = Physical(AF_INET);
        physical6 = Physical(AF_INET6);
        Check(api.ConvertInterfaceLuidToGuid(&luid, &guid));
        try {
            if (info.address && *info.address != "127.0.0.1" && *info.address != "::1") {
                const auto family = info.address->find(':') == std::string::npos ? AF_INET : AF_INET6;
                AddRoute(Prefix(*info.address, family, true), std::nullopt, true);
            }
            if (ipv4) ApplyIP(*ipv4, AF_INET, mtu);
            if (ipv6) ApplyIP(*ipv6, AF_INET6, mtu);
            if (dns && !dns->servers.empty()) {
                std::string servers;
                std::string servers6;
                for (const auto &server : dns->servers) {
                    const auto family = server.find(':') == std::string::npos ? AF_INET : AF_INET6;
                    Address(server, family);
                    if (dns->routesThroughVPN)
                        AddRoute(Prefix(server, family, true), std::nullopt, !*dns->routesThroughVPN);
                    auto &list = family == AF_INET ? servers : servers6;
                    if (!list.empty()) list += ',';
                    list += server;
                }
                std::string searches;
                for (const auto &suffix : dns->searchDomains.value_or(std::vector<std::string>{})) {
                    if (!searches.empty()) searches += ',';
                    searches += suffix;
                }
                auto serverText = Wide(servers);
                auto searchText = Wide(searches);
                auto domainText = Wide(dns->domainName.value_or(""));
                previousDns.Version = DNS_INTERFACE_SETTINGS_VERSION1;
                Check(api.GetInterfaceDnsSettings(guid, &previousDns));
                previousDns.Flags = DNS_SETTING_NAMESERVER | DNS_SETTING_SEARCHLIST | DNS_SETTING_DOMAIN;
                dnsSaved = true;
                DNS_INTERFACE_SETTINGS settings{};
                settings.Version = DNS_INTERFACE_SETTINGS_VERSION1;
                settings.Flags = DNS_SETTING_NAMESERVER | DNS_SETTING_SEARCHLIST | DNS_SETTING_DOMAIN;
                settings.NameServer = serverText.data();
                settings.SearchList = searchText.data();
                settings.Domain = domainText.data();
                Check(api.SetInterfaceDnsSettings(guid, &settings));
                if (!servers6.empty()) {
                    auto serverText6 = Wide(servers6);
                    DNS_INTERFACE_SETTINGS settings6{};
                    settings6.Version = DNS_INTERFACE_SETTINGS_VERSION1;
                    settings6.Flags = DNS_SETTING_IPV6 | DNS_SETTING_NAMESERVER;
                    settings6.NameServer = serverText6.data();
                    ipv6DnsChanged = true;
                    Check(api.SetInterfaceDnsSettings(guid, &settings6));
                }
            }
        } catch (...) {
            Clear();
            throw;
        }
    }

    bool Configure(const partout_socket_descriptor *sockets, size_t count) {
        if (!count) return true;
        if (count && !sockets) return false;
        const auto v4 = Physical(AF_INET);
        const auto v6 = Physical(AF_INET6);
        for (size_t i = 0; i < count; ++i) {
            WSAPROTOCOL_INFO protocol{};
            int length = sizeof(protocol);
            const SOCKET socket = static_cast<SOCKET>(sockets[i]);
            if (api.getsockopt(socket, SOL_SOCKET, SO_PROTOCOL_INFO, reinterpret_cast<char *>(&protocol), &length)) return false;
            if (protocol.iAddressFamily == AF_INET) {
                if (!v4.InterfaceIndex) return false;
                const DWORD index = htonl(v4.InterfaceIndex);
                if (api.setsockopt(socket, IPPROTO_IP, IP_UNICAST_IF, reinterpret_cast<const char *>(&index), sizeof(index))) return false;
            } else if (protocol.iAddressFamily == AF_INET6) {
                DWORD only = 1;
                length = sizeof(only);
                if (api.getsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, reinterpret_cast<char *>(&only), &length)) return false;
                if (!v6.InterfaceIndex && (only || !v4.InterfaceIndex)) return false;
                if (v6.InterfaceIndex) {
                    const DWORD index = v6.InterfaceIndex;
                    if (api.setsockopt(socket, IPPROTO_IPV6, IPV6_UNICAST_IF, reinterpret_cast<const char *>(&index), sizeof(index))) return false;
                }
                if (!only && v4.InterfaceIndex) {
                    const DWORD index = htonl(v4.InterfaceIndex);
                    if (api.setsockopt(socket, IPPROTO_IP, IP_UNICAST_IF, reinterpret_cast<const char *>(&index), sizeof(index))) return false;
                }
            } else {
                return false;
            }
        }
        return true;
    }
};
}
extern "C" void *NetworkSettingsCreate(void) {
    try {
        return new NetworkSettings;
    } catch (...) {
        return nullptr;
    }
}
extern "C" void NetworkSettingsDestroy(void *context) {
    delete static_cast<NetworkSettings *>(context);
}
extern "C" void NetworkSettingsClear(void *context) {
    if (!context) return;
    try {
        auto &settings = *static_cast<NetworkSettings *>(context);
        std::lock_guard<std::mutex> lock(settings.mutex);
        settings.Clear();
    } catch (...) {
        std::fprintf(stderr, "Wintun cleanup failed\n");
    }
}
extern "C" bool NetworkSettingsApply(void *context, NET_LUID luid, const char *json) {
    if (!context || !json) return false;
    try {
        auto &settings = *static_cast<NetworkSettings *>(context);
        std::lock_guard<std::mutex> lock(settings.mutex);
        settings.Apply(luid, json);
        return true;
    } catch (const nlohmann::json::exception &) {
        std::fprintf(stderr, "Wintun settings failed: invalid JSON model\n");
        return false;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Wintun settings failed: %s\n", error.what());
        return false;
    } catch (...) {
        return false;
    }
}
extern "C" bool NetworkSettingsConfigureSockets(void *context, const partout_socket_descriptor *sockets, size_t count) {
    if (!context) return false;
    try {
        auto &settings = *static_cast<NetworkSettings *>(context);
        std::lock_guard<std::mutex> lock(settings.mutex);
        return settings.Configure(sockets, count);
    } catch (...) {
        return false;
    }
}

void *NetworkSettingsCreateWithApi(const NetworkSettingsApi &api) {
    return new NetworkSettings(api);
}

extern "C" bool NetworkSettingsReachable(void *context) {
    if (!context) return false;
    try {
        auto &settings = *static_cast<NetworkSettings *>(context);
        std::lock_guard<std::mutex> lock(settings.mutex);
        return settings.Physical(AF_INET).InterfaceLuid.Value || settings.Physical(AF_INET6).InterfaceLuid.Value;
    } catch (...) {
        return false;
    }
}
