// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "tunnel_internal.h"
#include <cassert>
#include <limits>

int main() {
    using Status = winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus;
    std::string error;
    auto status = Partout::ReadTunnelConnectionStatus([]() -> Status {
        throw winrt::hresult_error(E_HANDLE);
    }, error);
    assert(!status && error.find("80070006") != std::string::npos);
    status = Partout::ReadTunnelConnectionStatus([] { return Status::Connected; }, error);
    assert(status == Status::Connected && error.empty());
    status = Partout::ReadTunnelConnectionStatus([]() -> Status {
        throw winrt::hresult_error(E_ACCESSDENIED);
    }, error);
    assert(!status && error.find("80070005") != std::string::npos);

    MIB_IF_ROW2 row{};
    row.Type = IF_TYPE_PPP;
    row.OperStatus = IfOperStatusUp;
    row.InOctets = 5ULL * 1024 * 1024 * 1024;
    row.OutOctets = 7ULL * 1024 * 1024 * 1024;
    auto environment = Partout::TunnelInterfaceEnvironment(row);
    assert(environment && environment->dataCount.received == row.InOctets);
    assert(environment->dataCount.sent == row.OutOctets);
    row.InOctets = 0;
    row.OutOctets = 0;
    environment = Partout::TunnelInterfaceEnvironment(row);
    assert(environment && environment->dataCount.received == 0 && environment->dataCount.sent == 0);
    row.Type = IF_TYPE_ETHERNET_CSMACD;
    assert(!Partout::TunnelInterfaceEnvironment(row));
    row.Type = IF_TYPE_TUNNEL;
    assert(Partout::TunnelInterfaceEnvironment(row));
    row.OperStatus = IfOperStatusDown;
    assert(!Partout::TunnelInterfaceEnvironment(row));
    row.OperStatus = IfOperStatusUp;
    row.InOctets = std::numeric_limits<ULONG64>::max();
    assert(!Partout::TunnelInterfaceEnvironment(row));
}
