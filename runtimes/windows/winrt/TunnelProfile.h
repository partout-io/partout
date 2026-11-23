// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <winrt/base.h>
#include <optional>
#include <string>

namespace Partout::WinRT::Profiles {
std::optional<std::string> DecodeId(const winrt::hstring &xml);
}
