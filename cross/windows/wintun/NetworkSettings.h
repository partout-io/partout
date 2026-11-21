// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "partout.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#ifdef __cplusplus
extern "C" {
#endif
void *NetworkSettingsCreate(void);
void NetworkSettingsDestroy(void *context);
bool NetworkSettingsApply(void *context, NET_LUID luid, const char *json);
void NetworkSettingsClear(void *context);
bool NetworkSettingsConfigureSockets(void *context, const partout_socket_descriptor *sockets, size_t count);
bool NetworkSettingsReachable(void *context);
#ifdef __cplusplus
}
#endif
