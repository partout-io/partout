// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <winrt/base.h>
#include <optional>
#include <string>

namespace Partout {
std::optional<std::string> DecodeTunnelProfileId(const winrt::hstring &xml);
}
