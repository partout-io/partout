// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "NetworkSettings.h"
#include "NetworkSettingsApi.h"
#include <partout.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace {
int addedAddresses, removedAddresses, addedRoutes, removedRoutes, dnsWrites, interfaceWrites;
bool failDns, failRoute, existingAddress;
bool failDelete, failSocket;
int socketFamily = AF_INET;
int socketWrites;
const char *settings = R"({
 "profile":{"id":"696F9011-BA2D-455F-A7BF-AD74874FD4F4","name":"test",
 "activeModulesIds":["ip","dns"],"modules":[
 {"type":"IP","value":{"id":"ip","mtu":1420,"ipv4":{"subnets":["192.0.2.2/24"],"includedRoutes":[{}],"excludedRoutes":[]}}},
 {"type":"DNS","value":{"id":"dns","protocolType":{"type":"cleartext"},"servers":["192.0.2.1"]}}
 ]},"originalModuleId":"ip"
})";
NetworkSettingsApi FakeApi() {
    NetworkSettingsApi api;
    api.GetIpForwardTable2 = [](ADDRESS_FAMILY family, PMIB_IPFORWARD_TABLE2 *result) -> NETIO_STATUS {
        *result = static_cast<PMIB_IPFORWARD_TABLE2>(std::calloc(1, sizeof(MIB_IPFORWARD_TABLE2)));
        (*result)->NumEntries = 1;
        auto &row = (*result)->Table[0];
        row.InterfaceIndex = 7;
        row.InterfaceLuid.Value = 7;
        row.DestinationPrefix.Prefix.si_family = family;
        row.NextHop.si_family = family;
        return NO_ERROR;
    };
    api.FreeMibTable = [](PVOID table) {
        std::free(table);
    };
    api.GetIfEntry2 = [](PMIB_IF_ROW2 row) -> NETIO_STATUS {
        row->OperStatus = IfOperStatusUp;
        row->Type = IF_TYPE_ETHERNET_CSMACD;
        return NO_ERROR;
    };
    api.GetIpInterfaceEntry = [](PMIB_IPINTERFACE_ROW row) -> NETIO_STATUS {
        row->NlMtu = 1500;
        row->Metric = 25;
        return NO_ERROR;
    };
    api.SetIpInterfaceEntry = [](PMIB_IPINTERFACE_ROW) -> NETIO_STATUS {
        ++interfaceWrites;
        return NO_ERROR;
    };
    api.ConvertInterfaceLuidToGuid = [](const NET_LUID *, GUID *guid) -> NETIO_STATUS {
        *guid = {};
        return NO_ERROR;
    };
    api.CreateUnicastIpAddressEntry = [](const MIB_UNICASTIPADDRESS_ROW *row) -> NETIO_STATUS {
        assert(row->OnLinkPrefixLength == (row->Address.si_family == AF_INET ? 24 : 64));
        if (existingAddress) return ERROR_OBJECT_ALREADY_EXISTS;
        ++addedAddresses;
        return NO_ERROR;
    };
    api.DeleteUnicastIpAddressEntry = [](const MIB_UNICASTIPADDRESS_ROW *) -> NETIO_STATUS {
        ++removedAddresses;
        return NO_ERROR;
    };
    api.CreateIpForwardEntry2 = [](const MIB_IPFORWARD_ROW2 *row) -> NETIO_STATUS {
        assert(row->DestinationPrefix.PrefixLength == 1 ||
               (row->DestinationPrefix.PrefixLength == 0 && row->InterfaceLuid.Value == 7));
        if (failRoute && addedRoutes == 1) return ERROR_ACCESS_DENIED;
        ++addedRoutes;
        return NO_ERROR;
    };
    api.DeleteIpForwardEntry2 = [](const MIB_IPFORWARD_ROW2 *) -> NETIO_STATUS {
        if (failDelete) return ERROR_ACCESS_DENIED;
        ++removedRoutes;
        return NO_ERROR;
    };
    api.GetInterfaceDnsSettings = [](GUID, DNS_INTERFACE_SETTINGS *value) -> DWORD {
        value->Flags = DNS_SETTING_NAMESERVER | DNS_SETTING_SEARCHLIST | DNS_SETTING_DOMAIN;
        return NO_ERROR;
    };
    api.FreeInterfaceDnsSettings = [](DNS_INTERFACE_SETTINGS *) {};
    api.SetInterfaceDnsSettings = [](GUID, const DNS_INTERFACE_SETTINGS *value) -> DWORD {
        ++dnsWrites;
        if (failDns && value->NameServer) return ERROR_ACCESS_DENIED;
        return NO_ERROR;
    };
    api.getsockopt = [](SOCKET, int, int option, char *value, int *) -> int {
        if (option == SO_PROTOCOL_INFO) reinterpret_cast<WSAPROTOCOL_INFO *>(value)->iAddressFamily = socketFamily;
        else if (option == IPV6_V6ONLY) *reinterpret_cast<DWORD *>(value) = 0;
        else return SOCKET_ERROR;
        return 0;
    };
    api.setsockopt = [](SOCKET, int level, int option, const char *value, int) -> int {
        assert(option == (level == IPPROTO_IP ? IP_UNICAST_IF : IPV6_UNICAST_IF));
        assert(*reinterpret_cast<const DWORD *>(value) == (level == IPPROTO_IP ? htonl(7) : 7));
        ++socketWrites;
        return failSocket ? SOCKET_ERROR : 0;
    };
    return api;
}
void Reset() {
    addedAddresses = removedAddresses = addedRoutes = removedRoutes = dnsWrites = interfaceWrites = 0;
    failDns = failRoute = existingAddress = failDelete = failSocket = false;
    socketWrites = 0;
}
}
int main() {
    assert(!partout_platform_bindings_init(nullptr));
    partout_daemon_bindings bindings{};
    const auto onStatus = [](void *, const char *) {};
    bindings.events.set_connection_status = onStatus;
    assert(partout_platform_bindings_init(&bindings));
    assert(bindings.events.set_connection_status == onStatus);
    assert(bindings.controller && bindings.controller_functions.set_tunnel && bindings.release);
    bindings.release(&bindings);
    assert(!bindings.controller);

    const auto api = FakeApi();
    NET_LUID luid{};
    luid.Value = 99;
    auto context = NetworkSettingsCreateWithApi(api);
    Reset();
    assert(NetworkSettingsApply(context, luid, settings));
    assert(addedAddresses == 1 && addedRoutes == 2 && dnsWrites == 1);
    NetworkSettingsClear(context);
    assert(removedAddresses == 1 && removedRoutes == 2 && dnsWrites == 2 && interfaceWrites == 2);
    NetworkSettingsClear(context);
    assert(removedAddresses == 1 && removedRoutes == 2 && dnsWrites == 2);
    Reset();
    failDns = true;
    assert(!NetworkSettingsApply(context, luid, settings));
    assert(removedAddresses == addedAddresses && removedRoutes == addedRoutes && dnsWrites == 2);
    Reset();
    failRoute = true;
    assert(!NetworkSettingsApply(context, luid, settings));
    assert(addedRoutes == 1 && removedRoutes == 1 && removedAddresses == 1);
    Reset();
    existingAddress = true;
    assert(NetworkSettingsApply(context, luid, settings));
    NetworkSettingsClear(context);
    assert(removedAddresses == 0);
    Reset();
    assert(!NetworkSettingsApply(context, luid, "{}"));
    assert(addedAddresses == 0 && addedRoutes == 0);
    assert(!NetworkSettingsConfigureSockets(context, nullptr, 1));
    const partout_socket_descriptor socket = 1;
    assert(NetworkSettingsConfigureSockets(context, &socket, 1));
    assert(socketWrites == 1);
    socketFamily = AF_INET6;
    assert(NetworkSettingsConfigureSockets(context, &socket, 1));
    assert(socketWrites == 3);
    failSocket = true;
    assert(!NetworkSettingsConfigureSockets(context, &socket, 1));
    Reset();
    std::string ipv6 = settings;
    ipv6.replace(ipv6.find("ipv4"), 4, "ipv6");
    ipv6.replace(ipv6.find("192.0.2.2/24"), 12, "2001:db8::2/64");
    ipv6.replace(ipv6.find("192.0.2.1"), 9, "2001:db8::1");
    assert(NetworkSettingsApply(context, luid, ipv6.c_str()));
    NetworkSettingsClear(context);
    assert(removedAddresses == 1 && removedRoutes == 2 && dnsWrites == 4);
    Reset();
    assert(NetworkSettingsApply(context, luid, settings));
    failDelete = true;
    NetworkSettingsClear(context);
    assert(removedRoutes == 0);
    failDelete = false;
    NetworkSettingsClear(context);
    assert(removedRoutes == 2);
    Reset();
    std::string excluded = settings;
    const auto offset = excluded.find("\"excludedRoutes\":[]");
    excluded.replace(offset, 19, "\"excludedRoutes\":[{\"destination\":\"0.0.0.0/0\"}]");
    assert(NetworkSettingsApply(context, luid, excluded.c_str()));
    assert(addedRoutes == 1); // An excluded default must suppress every tunnel route.
    NetworkSettingsClear(context);
    assert(removedRoutes == 1);
    NetworkSettingsDestroy(context);

    // Real Windows socket configuration, without sending packets or changing routes.
    WSADATA data{};
    assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);
    context = NetworkSettingsCreate();
    assert(context);
    if (NetworkSettingsReachable(context)) {
        const SOCKET native = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        assert(native != INVALID_SOCKET);
        const partout_socket_descriptor descriptor = native;
        assert(NetworkSettingsConfigureSockets(context, &descriptor, 1));
        DWORD index = 0;
        int size = sizeof(index);
        assert(getsockopt(native, IPPROTO_IP, IP_UNICAST_IF, reinterpret_cast<char *>(&index), &size) == 0);
        assert(index != 0);
        closesocket(native);
        std::puts("Native Windows IPv4 transport bypass passed");
    }
    NetworkSettingsDestroy(context);
    WSACleanup();
}
