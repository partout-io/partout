/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include "partout.h"

int main() {
    const char *id = partout_identifier;
    const char *ver = partout_version;
    printf("Partout version %s (%s)\n", ver, id);
    return 0;
}
