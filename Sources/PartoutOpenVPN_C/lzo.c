// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#ifdef OPENVPN_DEPRECATED_LZO

#include <stdlib.h>
#include <minilzo.h>
#include "openvpn/lzo.h"
#include "portable/common.h"

#define PP_LZO_ALLOC(var,size) \
    lzo_align_t __LZO_MMODEL var [ ((size) + (sizeof(lzo_align_t) - 1)) / sizeof(lzo_align_t) ]

#define LZO1X_1_15_MEM_COMPRESS ((lzo_uint32_t) (32768L * lzo_sizeof_dict_t))

struct _pp_lzo {
    unsigned char buf[LZO1X_1_15_MEM_COMPRESS];
    PP_LZO_ALLOC(wrkmem, LZO1X_1_MEM_COMPRESS);
};

pp_lzo pp_lzo_create() {
    if (lzo_init() != LZO_E_OK) {
        pp_assert(false && "LZO engine failed to initialize");
        abort();
        return NULL;
    }
    pp_lzo lzo = pp_alloc(sizeof(*lzo));
    return lzo;
}

void pp_lzo_free(pp_lzo lzo) {
    if (!lzo) return;
    pp_zero(lzo, sizeof(*lzo));
    pp_free(lzo);
}

unsigned char *pp_lzo_compress(pp_lzo lzo, size_t *dst_len, const unsigned char *src, size_t src_len) {
    pp_assert(dst_len);
    pp_assert(src);
    const size_t dst_max_len = src_len + src_len / 16 + 64 + 3;
    unsigned char *dst = pp_alloc(dst_max_len);
    lzo_uint dst_actual_len = 0;
    const int status = lzo1x_1_compress(src, src_len, dst, &dst_actual_len, lzo->wrkmem);
    if (status != LZO_E_OK) {
        goto failure;
    }
    // Fail if compressed payload is bigger than uncompressed
    if (dst_actual_len > src_len) {
        goto failure;
    }
    *dst_len = dst_actual_len;
    return dst;
failure:
    pp_free(dst);
    return NULL;
}

unsigned char *pp_lzo_decompress(pp_lzo lzo, size_t *dst_len, const unsigned char *src, size_t src_len) {
    pp_assert(dst_len);
    pp_assert(src);
    lzo_uint dst_actual_len = sizeof(lzo->buf);
    const int status = lzo1x_decompress_safe(src, src_len, lzo->buf, &dst_actual_len, NULL);
    if (status != LZO_E_OK) {
        return NULL;
    }
    unsigned char *dst = pp_alloc(dst_actual_len);
    memcpy(dst, lzo->buf, dst_actual_len);
    *dst_len = dst_actual_len;
    return dst;
}

#endif
