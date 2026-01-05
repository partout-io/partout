/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include <stdlib.h>
#include <assert.h>
#include "url.h"

#define URL_SEPARATOR '/'

const char *memrchr(const char *s, int c, size_t n);

struct _minif_url {
    const char *original;
    const char *subject;
    URL impl;
};

minif_url *minif_url_create(const char *string) {
    URL impl = { 0 };
    char *original = minif_strdup(string);
    char *subject = minif_strdup(string);
    if (!original || !subject) goto failure;
    int len = (int)strlen(subject);
    if (len > 1) {
        const char *trailing = subject + len - 1;
        while (trailing != subject && *trailing == URL_SEPARATOR) {
            --len;
            --trailing;
        }
    }
    if (url_parse(subject, len, NULL, &impl, URL_FLAG_RFC3986) < 0) goto failure;
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

const char *minif_url_get_scheme(minif_url *url, size_t *len) {
    if (url->impl.scheme.len == 0) return NULL;
    *len = url->impl.scheme.len;
    return url->impl.scheme.ptr;
}

const char *minif_url_get_host(minif_url *url, size_t *len) {
    if (url->impl.host_text.len == 0) return NULL;
    if (url->impl.host_type == URL_HOST_IPV6) {
        *len = url->impl.host_text.len - 2;
        return url->impl.host_text.ptr + 1;
    }
    *len = url->impl.host_text.len;
    return url->impl.host_text.ptr;
}

int minif_url_get_port(minif_url *url) {
    return url->impl.port;
}

const char *minif_url_get_path(minif_url *url, size_t *len) {
    if (url->impl.path.len == 0) return NULL;
    *len = url->impl.path.len;
    return url->impl.path.ptr;
}

const char *minif_url_get_query(minif_url *url, size_t *len) {
    if (url->impl.query.len == 0) return NULL;
    *len = url->impl.query.len;
    return url->impl.query.ptr;
}

const char *minif_url_get_fragment(minif_url *url, size_t *len) {
    if (url->impl.fragment.len == 0) return NULL;
    *len = url->impl.fragment.len;
    return url->impl.fragment.ptr;
}

const char *minif_url_get_last_path_component(minif_url *url, size_t *len) {
    if (url->impl.path.len == 0) return NULL;
    const char *p = memrchr(url->impl.path.ptr, URL_SEPARATOR, url->impl.path.len);
    // Return the full path
    if (!p) {
        *len = url->impl.path.len;
        return url->impl.path.ptr;
    }
    // Return the path after the URL_SEPARATOR
    ++p;
    const size_t offset = p - url->impl.path.ptr;
    *len = url->impl.path.len - offset;
    return p;
}

char *minif_url_alloc_decoded(const char *str, size_t len, size_t *dec_len) {
    // Force unsafe cast as url_percent_decode() has no side-effect
    URL_String comp = { (char *)str, (int)len };
    *dec_len = url_percent_decode(comp, NULL, 0);
    char *dec_str = (char *)calloc(1, *dec_len);
    const size_t redec_len = url_percent_decode(comp, dec_str, (int)*dec_len);
    assert(redec_len == *dec_len);
    return dec_str;
}

const char *memrchr(const char *s, int c, size_t n) {
    const char *p = (const char *)s + n;
    while (n--) {
        if (*--p == (char)c) return p;
    }
    return NULL;
}
