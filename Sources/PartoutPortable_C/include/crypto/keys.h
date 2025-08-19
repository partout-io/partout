/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

char *_Nullable pp_key_decrypted_from_path(const char *_Nonnull path,
                                           const char *_Nonnull passphrase);

char *_Nullable pp_key_decrypted_from_pem(const char *_Nonnull pem,
                                          const char *_Nonnull passphrase);
