/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include "uuid4.h"
#include <ctype.h>
#include <string.h>

// Dynamically allocated
const char *minif_uuid_create() {
    char buf[UUID4_LEN];
    uuid4_init();
    uuid4_generate(buf);
    return minif_strdup(buf);
}

bool minif_uuid_validate(const char *uuid) {
    if (!uuid) return false;
    size_t len = strlen(uuid);
    if (len != 36) return false;
    for (int i = 0; i < len; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (uuid[i] != '-') return false;
        } else if (!isxdigit((unsigned char)uuid[i])) {
            return false;
        }
    }
    return true;
}
