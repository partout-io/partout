// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "backend/NetworkMonitor.h"
#include <cassert>
#include <array>

int main() {
    using namespace Partout;
    const winrt::guid wifi{1, 0, 0, {}}, ethernet{2, 0, 0, {}}, mobile{3, 0, 0, {}};
    NetworkMonitor::Path path;
    assert(path.Update(wifi, true));

    // Both adapters remain connected with InternetAccess. Enumeration must not
    // keep Wi-Fi selected once Ethernet has a lower combined default-route cost.
    const NetworkMonitor::Preference wifi_preference{3, 50}, ethernet_preference{3, 10};
    const std::array adapters{wifi, ethernet};
    const std::array preferences{wifi_preference, ethernet_preference};
    const auto preference = [&](size_t i) { return std::optional{preferences[i]}; };
    NetworkMonitor::Path handoff;
    const auto initial = NetworkMonitor::SelectPhysical(1, preference);
    assert(initial && adapters[*initial] == wifi);
    assert(handoff.Update(adapters[*initial], true));
    const auto selected = NetworkMonitor::SelectPhysical(adapters.size(), preference);
    assert(selected && adapters[*selected] == ethernet);
    assert(handoff.Update(adapters[*selected], true));
    assert(!handoff.Update(adapters[*selected], true));
    assert(!NetworkMonitor::SelectPhysical(0, preference));
    assert(!NetworkMonitor::SelectPhysical(2, [](size_t) { return std::nullopt; }));
    assert((NetworkMonitor::Preference{3, 5}.IsBetterThan(ethernet_preference)));
    assert((ethernet_preference.IsBetterThan(NetworkMonitor::Preference{3, std::nullopt})));
    assert((NetworkMonitor::Preference{3, std::nullopt}.IsBetterThan(NetworkMonitor::Preference{1, std::nullopt})));
    assert(!path.Update(wifi, true));
    assert(path.Update(ethernet, true));
    assert(!path.Update(ethernet, true));
    assert(path.Update(mobile, true));
    assert(path.Update({}, false));
    assert(!path.Update({}, false));
    assert(path.Update(wifi, true));

    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    NetworkMonitor monitor;
    unsigned calls = 0;
    monitor.Start([&](bool, bool changed) {
        assert(!changed);
        ++calls;
    });
    assert(calls == 1);
    monitor.Stop();
    monitor.Start([&](bool, bool changed) {
        assert(!changed);
        ++calls;
    });
    assert(calls == 2);
    monitor.Stop();
}
