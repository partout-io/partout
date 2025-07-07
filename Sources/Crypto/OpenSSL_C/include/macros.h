//
//  macros.h
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

#pragma once

#define CRYPTO_OPENSSL_SUCCESS(code) (code > 0)

#define CRYPTO_OPENSSL_TRACK_STATUS(code) if (code > 0) code =

#define CRYPTO_OPENSSL_RETURN_STATUS(code, raised)\
if (code <= 0) {\
    if (error) {\
        *error = raised;\
    }\
    return false;\
}\
return true;

#define CRYPTO_OPENSSL_RETURN_LENGTH(code, length, raised)\
if (code <= 0 || length == 0) {\
    if (error) {\
        *error = raised;\
    }\
    return 0;\
}\
return length;
