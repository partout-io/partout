/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <assert.h>
#include "partout/partout.h"
#include "portable/tunctrl.h"

static
void test_working_wrapper(struct __partout_tun_ctrl *thiz) {
    assert(thiz);
    pp_tun_ctrl_test_working_wrapper(thiz->ref);
}

static
void *set_tunnel(struct __partout_tun_ctrl *thiz,
                 const char *info_json) {
    assert(thiz);
    return pp_tun_ctrl_set_tunnel(thiz->ref, info_json);
}

static
void configure_sockets(struct __partout_tun_ctrl *thiz,
                       const int *fds, const size_t fds_len) {
    assert(thiz);
    pp_tun_ctrl_configure_sockets(thiz->ref, fds, fds_len);
}

static
void clear_tunnel(struct __partout_tun_ctrl *thiz,
                  void *tun_impl) {
    assert(thiz);
    pp_tun_ctrl_clear_tunnel(thiz->ref, tun_impl);
}

partout_tun_ctrl partout_tun_ctrl_make(void *ref) {
    partout_tun_ctrl obj = {
        ref,
        test_working_wrapper,
        set_tunnel,
        configure_sockets,
        clear_tunnel
    };
    return obj;
}
