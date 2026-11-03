// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <winsock2.h>
#include <ws2ipdef.h>
#include <netioapi.h>
#include <winrt/base.h>
#include "models/TunnelSnapshotEnvironment.h"
#include <optional>
#include <string>

namespace Partout {
std::optional<Models::TunnelSnapshotEnvironment> TunnelInterfaceEnvironment(const MIB_IF_ROW2 &row);
}
