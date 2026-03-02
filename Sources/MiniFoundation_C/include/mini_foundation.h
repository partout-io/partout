/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma clang assume_nonnull begin

#ifdef __cplusplus
extern "C" {
#endif

char *minif_strdup(const char *string);
FILE *_Nullable minif_fopen(const char *filename, const char *mode);
bool minif_prng_do(void *dst, size_t len);

typedef struct _minif_rx_result minif_rx_result;
typedef struct _minif_rx_match minif_rx_match;
minif_rx_result *_Nullable minif_rx_groups(const char *pattern, const char *input);
minif_rx_result *_Nullable minif_rx_matches(const char *pattern, const char *input);
void minif_rx_result_free(minif_rx_result *result);
size_t minif_rx_result_get_items_count(const minif_rx_result *result);
const minif_rx_match *minif_rx_result_get_item(const minif_rx_result *result, int index);
const char *minif_rx_match_get_token(const minif_rx_match *item);
size_t minif_rx_match_get_location(const minif_rx_match *item);
size_t minif_rx_match_get_length(const minif_rx_match *item);

#ifdef __cplusplus
}
#endif

#pragma clang assume_nonnull end
