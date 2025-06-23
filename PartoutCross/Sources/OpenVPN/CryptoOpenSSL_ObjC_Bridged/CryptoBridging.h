//
//  CryptoBridging.h
//  Partout
//
//  Created by Davide De Rosa on 6/15/25.
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

#import "CryptoOpenSSL/CryptoMacros.h"
#import "CryptoOpenSSL/ZeroingData.h"
#import "crypto/zeroing_data.h"

@interface ZeroingData (C)

- (zeroing_data_t *)ptr;

@end

static inline
crypto_flags_t crypto_flags_from(const CryptoFlags *flags) {
    crypto_flags_t cf = { 0 };
    if (flags) {
        cf.ad = flags->ad;
        cf.ad_len = flags->adLength;
        cf.iv = flags->iv;
        cf.iv_len = flags->ivLength;
        cf.for_testing = flags->forTesting;
    }
    return cf;
}
