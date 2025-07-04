//
//  allocation.h
//  Partout
//
//  Created by Davide De Rosa on 3/3/17.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#pragma once

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline
void *_Nonnull pp_alloc_crypto(size_t size) {
    void *memory = calloc(1, size);
    if (!memory) {
        fputs("pp_alloc_crypto: malloc() call failed", stderr);
        abort();
    }
    return memory;
}

/// - Parameters:
///   - size: The base number of bytes.
///   - overhead: The extra number of bytes.
/// - Returns: The number of bytes to store a crypto buffer safely.
static inline
size_t pp_alloc_crypto_capacity(size_t size, size_t overhead) {

#define MAX_BLOCK_SIZE 16  // AES only, block is 128-bit

    // encryption, byte-alignment, overhead (e.g. IV, digest)
    return 2 * size + MAX_BLOCK_SIZE + overhead;
}

static inline
void pp_zero(void *_Nonnull ptr, size_t count) {
#ifdef bzero
    bzero(ptr, count);
#else
    memset(ptr, 0, count);
#endif
}

static inline
char *_Nonnull pp_dup(const char *_Nonnull str) {
#ifdef _WIN32
    char *ptr = _strdup(str);
#else
    char *ptr = strdup(str);
#endif
    if (!ptr) {
        fputs("pp_dup: strdup() call failed", stderr);
        abort();
    }
    return ptr;
}
