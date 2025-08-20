/*
 * Copyright (C) 1996-2017 Markus Franz Xaver Johannes Oberhumer
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

/*
 * NOTE:
 *   the full LZO package can be found at
 *   http://www.oberhumer.com/opensource/lzo/
 */


#ifndef __MINILZO_H_INCLUDED
#define __MINILZO_H_INCLUDED 1

#define MINILZO_VERSION         0x20a0  /* 2.10 */

#if defined(__LZOCONF_H_INCLUDED)
#  error "you cannot use both LZO and miniLZO"
#endif

/* internal Autoconf configuration file - only used when building miniLZO */
#ifdef MINILZO_HAVE_CONFIG_H
#  include <config.h>
#endif
#include <limits.h>
#include <stddef.h>

#ifndef __LZODEFS_H_INCLUDED
#include "lzodefs.h"
#endif
#undef LZO_HAVE_CONFIG_H
#include "lzoconf.h"

#if !defined(LZO_VERSION) || (LZO_VERSION != MINILZO_VERSION)
#  error "version mismatch in header files"
#endif


#ifdef __cplusplus
extern "C" {
#endif


/***********************************************************************
//
************************************************************************/

/* Memory required for the wrkmem parameter.
 * When the required size is 0, you can also pass a NULL pointer.
 */

#define LZO1X_MEM_COMPRESS      LZO1X_1_MEM_COMPRESS
#define LZO1X_1_MEM_COMPRESS    ((lzo_uint32_t) (16384L * lzo_sizeof_dict_t))
#define LZO1X_MEM_DECOMPRESS    (0)


/* compression */
LZO_EXTERN(int)
lzo1x_1_compress        ( const lzo_bytep src, lzo_uint  src_len,
                                lzo_bytep dst, lzo_uintp dst_len,
                                lzo_voidp wrkmem );

/* decompression */
LZO_EXTERN(int)
lzo1x_decompress        ( const lzo_bytep src, lzo_uint  src_len,
                                lzo_bytep dst, lzo_uintp dst_len,
                                lzo_voidp wrkmem /* NOT USED */ );

/* safe decompression with overrun testing */
LZO_EXTERN(int)
lzo1x_decompress_safe   ( const lzo_bytep src, lzo_uint  src_len,
                                lzo_bytep dst, lzo_uintp dst_len,
                                lzo_voidp wrkmem /* NOT USED */ );


#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* already included */


/* vim:set ts=4 sw=4 et: */
