/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <string.h>
#include "portable/endian.h"
#include "openvpn/mss_fix.h"

static const uint8_t FLAG_SYN  = 2;
static const uint8_t PROTO_TCP = 6;
static const uint8_t OPT_END   = 0;
static const uint8_t OPT_NOP   = 1;
static const uint8_t OPT_MSS   = 2;

static inline uint16_t read_u16(const uint8_t *ptr)
{
    uint16_t value;
    memcpy(&value, ptr, sizeof(value));
    return value;
}

static inline void write_u16(uint8_t *ptr, uint16_t value)
{
    memcpy(ptr, &value, sizeof(value));
}

static inline
void mss_update_sum(uint8_t *sum_ptr, uint8_t *val_ptr, uint16_t new_val)
{
    const uint16_t old_sum = read_u16(sum_ptr);
    const uint16_t old_val = read_u16(val_ptr);
    uint32_t sum = (~pp_endian_ntohs(old_sum) & 0xffff) +
                   (~pp_endian_ntohs(old_val) & 0xffff) +
                   new_val;
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    write_u16(sum_ptr, pp_endian_htons(~sum & 0xffff));
    write_u16(val_ptr, pp_endian_htons(new_val));
}

void openvpn_mss_fix(uint8_t *data, size_t data_len, uint16_t mss)
{
    if (!data || data_len == 0 || mss == 0) {
        return;
    }

    size_t tcp_offset;
    const uint8_t version = data[0] >> 4;
    if (version == 4) {
        if (data_len < 20 || data[9] != PROTO_TCP) {
            return;
        }
        if ((data[6] & 0x1f) != 0 || data[7] != 0) {
            return;
        }
        const size_t ip_header_len = (size_t)(data[0] & 0x0f) * 4;
        if (ip_header_len < 20 || ip_header_len > data_len) {
            return;
        }
        tcp_offset = ip_header_len;
    } else if (version == 6) {
        if (data_len < 40 || data[6] != PROTO_TCP) {
            return;
        }
        tcp_offset = 40;
    } else {
        return;
    }

    if (tcp_offset > data_len || data_len - tcp_offset < 20) {
        return;
    }

    uint8_t *tcp = data + tcp_offset;
    if (!(tcp[13] & FLAG_SYN)) {
        return;
    }

    const size_t tcp_header_len = (size_t)(tcp[12] >> 4) * 4;
    if (tcp_header_len < 20 || tcp_header_len > data_len - tcp_offset) {
        return;
    }

    uint8_t *options = tcp + 20;
    const size_t options_len = tcp_header_len - 20;
    for (size_t offset = 0; offset < options_len;) {
        const uint8_t kind = options[offset];
        if (kind == OPT_END) {
            return;
        }
        if (kind == OPT_NOP) {
            ++offset;
            continue;
        }
        if (offset + 2 > options_len) {
            return;
        }
        const uint8_t option_len = options[offset + 1];
        if (option_len < 2 || option_len > options_len - offset) {
            return;
        }
        if (kind == OPT_MSS && option_len == 4) {
            uint8_t *mss_ptr = options + offset + 2;
            if (pp_endian_ntohs(read_u16(mss_ptr)) <= mss) {
                return;
            }
            mss_update_sum(tcp + 16, mss_ptr, mss);
            return;
        }
        offset += option_len;
    }
}
