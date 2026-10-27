// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "../../../cross/windows/src/network.h"
#include "../../../cross/windows/src/network_internal.h"
#include <cassert>
#include <array>

int main() {
    using namespace Partout;
    const winrt::guid wifi{1, 0, 0, {}}, ethernet{2, 0, 0, {}}, mobile{3, 0, 0, {}};
    NetworkPath path;
    assert(path.Update(wifi, true));

    // Both adapters remain connected with InternetAccess. Enumeration must not
    // keep Wi-Fi selected once Ethernet has a lower combined default-route cost.
    const NetworkPreference wifi_preference{3, 50}, ethernet_preference{3, 10};
    const std::array adapters{wifi, ethernet};
    const std::array preferences{wifi_preference, ethernet_preference};
    const auto preference = [&](size_t i) { return std::optional{preferences[i]}; };
    NetworkPath handoff;
    const auto initial = SelectPhysicalNetwork(1, preference);
    assert(initial && adapters[*initial] == wifi);
    assert(handoff.Update(adapters[*initial], true));
    const auto selected = SelectPhysicalNetwork(adapters.size(), preference);
    assert(selected && adapters[*selected] == ethernet);
    assert(handoff.Update(adapters[*selected], true));
    assert(!handoff.Update(adapters[*selected], true));
    assert(!SelectPhysicalNetwork(0, preference));
    assert(!SelectPhysicalNetwork(2, [](size_t) { return std::nullopt; }));
    assert((NetworkPreference{3, 5}.IsBetterThan(ethernet_preference)));
    assert((ethernet_preference.IsBetterThan(NetworkPreference{3, std::nullopt})));
    assert((NetworkPreference{3, std::nullopt}.IsBetterThan(NetworkPreference{1, std::nullopt})));
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
