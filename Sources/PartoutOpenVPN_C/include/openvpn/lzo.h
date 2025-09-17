/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>

typedef struct _pp_lzo *pp_lzo;

pp_lzo _Nullable pp_lzo_create();
void pp_lzo_free(pp_lzo _Nonnull lzo);

unsigned char *_Nullable pp_lzo_compress(pp_lzo _Nonnull lzo, size_t *_Nonnull dst_len,
                                         const unsigned char *_Nonnull src, size_t src_len);
unsigned char *_Nullable pp_lzo_decompress(pp_lzo _Nonnull lzo, size_t *_Nonnull dst_len,
                                           const unsigned char *_Nonnull src, size_t src_len);
