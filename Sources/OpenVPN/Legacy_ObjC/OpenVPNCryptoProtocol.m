// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <Foundation/Foundation.h>

#import "OpenVPNCryptoProtocol.h"

@interface OpenVPNCryptoOptions ()

@property (nonatomic, copy) NSString *cipherAlgorithm;
@property (nonatomic, copy) NSString *digestAlgorithm;
@property (nonatomic, strong) ZeroingData *cipherEncKey;
@property (nonatomic, strong) ZeroingData *cipherDecKey;
@property (nonatomic, strong) ZeroingData *hmacEncKey;
@property (nonatomic, strong) ZeroingData *hmacDecKey;

@end

@implementation OpenVPNCryptoOptions

- (instancetype)initWithCipherAlgorithm:(NSString *)cipherAlgorithm
                        digestAlgorithm:(NSString *)digestAlgorithm
                           cipherEncKey:(ZeroingData *)cipherEncKey
                           cipherDecKey:(ZeroingData *)cipherDecKey
                             hmacEncKey:(ZeroingData *)hmacEncKey
                             hmacDecKey:(ZeroingData *)hmacDecKey
{
    NSParameterAssert(cipherAlgorithm || digestAlgorithm);
    NSParameterAssert((cipherEncKey && cipherDecKey) || (hmacEncKey && hmacDecKey));

    if ((self = [super init])) {
        self.cipherAlgorithm = [cipherAlgorithm lowercaseString];
        self.digestAlgorithm = [digestAlgorithm lowercaseString];
        self.cipherEncKey = cipherEncKey;
        self.cipherDecKey = cipherDecKey;
        self.hmacEncKey = hmacEncKey;
        self.hmacDecKey = hmacDecKey;
    }
    return self;
}

@end
