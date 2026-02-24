/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static const char base64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static const int8_t base64_dec_table[256] = {
    ['A'] =  0, ['B'] =  1, ['C'] =  2, ['D'] =  3,
    ['E'] =  4, ['F'] =  5, ['G'] =  6, ['H'] =  7,
    ['I'] =  8, ['J'] =  9, ['K'] = 10, ['L'] = 11,
    ['M'] = 12, ['N'] = 13, ['O'] = 14, ['P'] = 15,
    ['Q'] = 16, ['R'] = 17, ['S'] = 18, ['T'] = 19,
    ['U'] = 20, ['V'] = 21, ['W'] = 22, ['X'] = 23,
    ['Y'] = 24, ['Z'] = 25,
    ['a'] = 26, ['b'] = 27, ['c'] = 28, ['d'] = 29,
    ['e'] = 30, ['f'] = 31, ['g'] = 32, ['h'] = 33,
    ['i'] = 34, ['j'] = 35, ['k'] = 36, ['l'] = 37,
    ['m'] = 38, ['n'] = 39, ['o'] = 40, ['p'] = 41,
    ['q'] = 42, ['r'] = 43, ['s'] = 44, ['t'] = 45,
    ['u'] = 46, ['v'] = 47, ['w'] = 48, ['x'] = 49,
    ['y'] = 50, ['z'] = 51,
    ['0'] = 52, ['1'] = 53, ['2'] = 54, ['3'] = 55,
    ['4'] = 56, ['5'] = 57, ['6'] = 58, ['7'] = 59,
    ['8'] = 60, ['9'] = 61, ['+'] = 62, ['/'] = 63,
};

// Dynamically allocated
char *minif_base64_encode(const uint8_t *data, size_t len, size_t *out_len) {
    size_t enc_len = 4 * ((len + 2) / 3); // 4 chars per 3 bytes
    char *enc = malloc(enc_len + 1);
    if (!enc) return NULL;

    size_t i = 0, j = 0;
    while (i < len) {
        uint8_t octet_a = data[i++];
        uint8_t octet_b = (i < len) ? data[i++] : 0;
        uint8_t octet_c = (i < len) ? data[i++] : 0;

        uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        enc[j++] = base64_table[(triple >> 18) & 0x3F];
        enc[j++] = base64_table[(triple >> 12) & 0x3F];
        enc[j++] = (i - 1 > len) ? '=' : base64_table[(triple >> 6) & 0x3F];
        enc[j++] = (i > len)     ? '=' : base64_table[triple & 0x3F];
    }

    // Fix padding for last block
    size_t mod = len % 3;
    if (mod) {
        enc[enc_len - 1] = '=';
        if (mod == 1)
            enc[enc_len - 2] = '=';
    }

    enc[enc_len] = '\0';
    if (out_len) *out_len = enc_len;
    return enc;
}

// Dynamically allocated
uint8_t *minif_base64_decode(const char *str, size_t len, size_t *out_len) {
    if (len % 4 != 0) return NULL;

    size_t padding = 0;
    if (len >= 1 && str[len - 1] == '=') padding++;
    if (len >= 2 && str[len - 2] == '=') padding++;

    size_t dec_len = (len / 4) * 3 - padding;
    uint8_t *dec = malloc(dec_len);
    if (!dec) return NULL;

    size_t i = 0, j = 0;
    while (i < len) {
        uint32_t sextet_a = str[i] == '=' ? 0 : base64_dec_table[(uint8_t)str[i]]; i++;
        uint32_t sextet_b = str[i] == '=' ? 0 : base64_dec_table[(uint8_t)str[i]]; i++;
        uint32_t sextet_c = str[i] == '=' ? 0 : base64_dec_table[(uint8_t)str[i]]; i++;
        uint32_t sextet_d = str[i] == '=' ? 0 : base64_dec_table[(uint8_t)str[i]]; i++;

        uint32_t triple = (sextet_a << 18) | (sextet_b << 12) | (sextet_c << 6) | sextet_d;

        if (j < dec_len) dec[j++] = (triple >> 16) & 0xFF;
        if (j < dec_len) dec[j++] = (triple >> 8) & 0xFF;
        if (j < dec_len) dec[j++] = triple & 0xFF;
    }

    if (out_len) *out_len = dec_len;
    return dec;
}
