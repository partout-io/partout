/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include "partout.h"

int main() {
    const char *id = PARTOUT_IDENTIFIER;
    const char *ver = PARTOUT_VERSION;
    printf("Partout version %s (%s)\n", ver, id);
    return 0;
}
