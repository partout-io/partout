// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <string>

namespace Partout {
// Connection-only authentication. Never written to an installed profile.
struct TunnelCredentials {
    std::string username;
    std::string password;
};
}
