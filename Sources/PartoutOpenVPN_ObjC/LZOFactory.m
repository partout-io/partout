// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import "LZOFactory.h"
#import "StandardLZO.h"

static NSString *const LZOClassName = @"StandardLZO";

static Class LZOClass(void)
{
    return [StandardLZO class];
}

@implementation LZOFactory

+ (id<CompressionProvider>)create
{
    Class clazz = LZOClass();
    if (!clazz) {
        return nil;
    }
    return [[clazz alloc] init];
}

@end
