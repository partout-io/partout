/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#pragma clang assume_nonnull begin

char *_Nullable pp_key_decrypted_from_path(const char *path,
                                           const char *passphrase);

char *_Nullable pp_key_decrypted_from_pem(const char *pem,
                                          const char *passphrase);

#pragma clang assume_nonnull end
