// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "TunnelInternal.h"
#include <cassert>
#include <limits>

int main() {
    assert(Partout::WinRT::Profiles::NamesEqual(L"Office", L"Office"));
    assert(Partout::WinRT::Profiles::NamesEqual(L"Office", L"office"));
    assert(Partout::WinRT::Profiles::NamesEqual(L"office", L"OFFICE"));
    assert(Partout::WinRT::Profiles::NamesEqual(L"B\u00fcro", L"B\u00dcRO"));
    assert(!Partout::WinRT::Profiles::NamesEqual(L"Office", L"Home"));
    assert(!Partout::WinRT::Profiles::NamesEqual(L"Office", L"Office 2"));

    using Status = winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus;
    std::string error;
    auto status = Partout::WinRT::Tunnels::ReadConnectionStatus([]() -> Status {
        throw winrt::hresult_error(E_HANDLE);
    }, error);
    assert(!status && error.find("80070006") != std::string::npos);
    status = Partout::WinRT::Tunnels::ReadConnectionStatus([] { return Status::Connected; }, error);
    assert(status == Status::Connected && error.empty());
    status = Partout::WinRT::Tunnels::ReadConnectionStatus([]() -> Status {
        throw winrt::hresult_error(E_ACCESSDENIED);
    }, error);
    assert(!status && error.find("80070005") != std::string::npos);

    MIB_IF_ROW2 row{};
    row.Type = IF_TYPE_PPP;
    row.OperStatus = IfOperStatusUp;
    row.InOctets = 5ULL * 1024 * 1024 * 1024;
    row.OutOctets = 7ULL * 1024 * 1024 * 1024;
    auto environment = Partout::WinRT::Tunnels::InterfaceEnvironment(row);
    assert(environment && environment->dataCount.received == row.InOctets);
    assert(environment->dataCount.sent == row.OutOctets);
    row.InOctets = 0;
    row.OutOctets = 0;
    environment = Partout::WinRT::Tunnels::InterfaceEnvironment(row);
    assert(environment && environment->dataCount.received == 0 && environment->dataCount.sent == 0);
    row.Type = IF_TYPE_ETHERNET_CSMACD;
    assert(!Partout::WinRT::Tunnels::InterfaceEnvironment(row));
    row.Type = IF_TYPE_TUNNEL;
    assert(Partout::WinRT::Tunnels::InterfaceEnvironment(row));
    row.OperStatus = IfOperStatusDown;
    assert(!Partout::WinRT::Tunnels::InterfaceEnvironment(row));
    row.OperStatus = IfOperStatusUp;
    row.InOctets = std::numeric_limits<ULONG64>::max();
    assert(!Partout::WinRT::Tunnels::InterfaceEnvironment(row));
}
