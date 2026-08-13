/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

typedef struct __pp_lib_struct *pp_lib;

pp_lib pp_lib_create(const char *path);
void pp_lib_free(pp_lib lib);
void *pp_lib_load(const pp_lib lib, const char *symbol);
