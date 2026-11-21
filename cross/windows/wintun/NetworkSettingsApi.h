// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>

struct NetworkSettingsApi {
    decltype(&::GetIpForwardTable2) GetIpForwardTable2 = &::GetIpForwardTable2;
    decltype(&::GetIfEntry2) GetIfEntry2 = &::GetIfEntry2;
    decltype(&::GetIpInterfaceEntry) GetIpInterfaceEntry = &::GetIpInterfaceEntry;
    decltype(&::FreeMibTable) FreeMibTable = &::FreeMibTable;
    decltype(&::SetInterfaceDnsSettings) SetInterfaceDnsSettings = &::SetInterfaceDnsSettings;
    decltype(&::FreeInterfaceDnsSettings) FreeInterfaceDnsSettings = &::FreeInterfaceDnsSettings;
    decltype(&::DeleteIpForwardEntry2) DeleteIpForwardEntry2 = &::DeleteIpForwardEntry2;
    decltype(&::DeleteUnicastIpAddressEntry) DeleteUnicastIpAddressEntry = &::DeleteUnicastIpAddressEntry;
    decltype(&::SetIpInterfaceEntry) SetIpInterfaceEntry = &::SetIpInterfaceEntry;
    decltype(&::CreateIpForwardEntry2) CreateIpForwardEntry2 = &::CreateIpForwardEntry2;
    decltype(&::CreateUnicastIpAddressEntry) CreateUnicastIpAddressEntry = &::CreateUnicastIpAddressEntry;
    decltype(&::ConvertInterfaceLuidToGuid) ConvertInterfaceLuidToGuid = &::ConvertInterfaceLuidToGuid;
    decltype(&::GetInterfaceDnsSettings) GetInterfaceDnsSettings = &::GetInterfaceDnsSettings;
    decltype(&::getsockopt) getsockopt = &::getsockopt;
    decltype(&::setsockopt) setsockopt = &::setsockopt;
};

void *NetworkSettingsCreateWithApi(const NetworkSettingsApi &api);
