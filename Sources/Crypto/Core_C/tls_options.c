//
//  tls_options.c
//  Partout
//
//  Created by Davide De Rosa on 7/3/25.
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

#include "crypto/allocation.h"
#include "crypto/tls.h"

tls_channel_options *_Nonnull tls_channel_options_create(int sec_level,
                                                         size_t buf_len,
                                                         bool eku,
                                                         bool san_host,
                                                         const char *_Nonnull ca_path,
                                                         const char *_Nullable cert_pem,
                                                         const char *_Nullable key_pem,
                                                         const char *_Nullable hostname,
                                                         void (*_Nonnull on_verify_failure)()) {

    pp_assert(ca_path && on_verify_failure);

    tls_channel_options *opt = pp_alloc_crypto(sizeof(tls_channel_options));
    opt->sec_level = sec_level;
    opt->buf_len = buf_len;
    opt->eku = eku;
    opt->san_host = san_host;
    opt->ca_path = pp_dup(ca_path);
    opt->cert_pem = cert_pem ? pp_dup(cert_pem) : NULL;
    opt->key_pem = key_pem ? pp_dup(key_pem) : NULL;
    opt->hostname = hostname ? pp_dup(hostname) : NULL;
    opt->on_verify_failure = on_verify_failure;
    return opt;
}

void tls_channel_options_free(tls_channel_options *_Nonnull opt) {
    free((char *)opt->ca_path);
    free((char *)opt->cert_pem);
    free((char *)opt->key_pem);
    free((char *)opt->hostname);
    free(opt);
}
