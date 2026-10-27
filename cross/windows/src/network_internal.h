// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#include <winrt/base.h>
#include <functional>
#include <optional>

namespace Partout {
// Adapter identity matters even when reachability remains true during a handoff.
struct NetworkPath {
    winrt::guid adapter{};
    bool reachable = false;
    bool initialized = false;

    bool Update(winrt::guid id, bool available);
};

// A default route outranks a local-only path; lower combined metrics win.
struct NetworkPreference {
    uint32_t connectivity = 0;
    std::optional<uint64_t> metric;

    bool IsBetterThan(const NetworkPreference &other) const;
};

// A missing preference excludes an unusable profile from selection.
std::optional<size_t> SelectPhysicalNetwork(size_t count,
    const std::function<std::optional<NetworkPreference>(size_t)> &preference);
} // namespace Partout
