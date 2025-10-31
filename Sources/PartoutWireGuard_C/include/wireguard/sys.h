/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2025 WireGuard LLC. All Rights Reserved.
 */

#pragma once

#ifndef _WIN32

#include <sys/types.h>
#include "wireguard/key.h"
#include "wireguard/x25519.h"

#ifdef __APPLE__
#include <sys/kern_control.h>
// XXX: Trick to expose macro to Swift
#undef CTLIOCGINFO
#define CTLIOCGINFO 0xc0644e03UL
#endif

#endif
