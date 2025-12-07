/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include <stdlib.h>
#include "yuarel.h"

struct _minif_url {
    const char *original;
    const char *subject;
    struct yuarel impl;
};

minif_url *minif_url_create(const char *string) {
    struct yuarel impl = { 0 };
    char *original = minif_strdup(string);
    char *subject = minif_strdup(string);
    if (!original || !subject) goto failure;
    if (yuarel_parse(&impl, subject) != 0) goto failure;
    minif_url *url = (minif_url *)calloc(1, sizeof(*url));
    url->original = original;
    url->subject = subject;
    url->impl = impl;
    return url;
failure:
    if (original) free(original);
    if (subject) free(subject);
    return NULL;
}

void minif_url_free(minif_url *url) {
    if (!url) return;
    free((void *)url->original);
    free((void *)url->subject);
    free(url);
}

const char *minif_url_get_string(minif_url *url) {
    return url->original;
}

const char *minif_url_get_scheme(minif_url *url) {
    return url->impl.scheme;
}

const char *minif_url_get_host(minif_url *url) {
    return url->impl.host;
}

int minif_url_get_port(minif_url *url) {
    return url->impl.port;
}

const char *minif_url_get_path(minif_url *url) {
    return url->impl.path;
}

const char *minif_url_alloc_last_path(minif_url *url) {
    if (!url->impl.path) return NULL;
    char *parts[256];
    char *subject = minif_strdup(url->impl.path);
    const int num = yuarel_split_path(subject, parts, sizeof(parts));
    if (num <= 0) goto failure;
    const char *last_part = minif_strdup(parts[num - 1]);
    free(subject);
    return last_part;
failure:
    free(subject);
    return NULL;
}

const char *minif_url_get_query(minif_url *url) {
    return url->impl.query;
}

const char *_Nullable minif_url_get_fragment(minif_url *url) {
    return url->impl.fragment;
}
