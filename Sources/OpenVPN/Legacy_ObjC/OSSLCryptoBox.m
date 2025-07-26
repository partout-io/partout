// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <openssl/evp.h>
#import <openssl/hmac.h>
#import <openssl/rand.h>

#import "OSSLCryptoBox.h"
#import "CryptoCBC+OpenVPN.h"
#import "CryptoAEAD+OpenVPN.h"
#import "CryptoCTR+OpenVPN.h"
#import "Errors.h"
#import "PacketMacros.h"

@import _PartoutCryptoOpenSSL_ObjC;

static const NSInteger CryptoAEADTagLength = 16;
static const NSInteger CryptoAEADIdLength = PacketIdLength;
static const NSInteger CryptoCTRTagLength = 32;
static const NSInteger CryptoCTRPayloadLength = PacketOpcodeLength + PacketSessionIdLength + PacketReplayIdLength + PacketReplayTimestampLength;

@interface OSSLCryptoBox ()

@property (nonatomic, strong) OpenVPNCryptoOptions *options;

@property (nonatomic, strong) id<Encrypter, DataPathEncrypterProvider> encrypter;
@property (nonatomic, strong) id<Decrypter, DataPathDecrypterProvider> decrypter;

@end

@implementation OSSLCryptoBox

#pragma mark Initialization

- (instancetype)initWithSeed:(ZeroingData *)seed
{
    if ((self = [super init])) {
        unsigned char x[1];
        // make sure its initialized before seeding
        if (RAND_bytes(x, 1) != 1) {
            return nil;
        }
        RAND_seed(seed.bytes, (int)seed.length);
    }
    return self;
}

- (void)dealloc
{
    self.encrypter = nil;
    self.decrypter = nil;
}

// these keys are coming from the OpenVPN negotiation despite the cipher
- (BOOL)configureWithOptions:(OpenVPNCryptoOptions *)options error:(NSError *__autoreleasing  *)error
{
    NSAssert(self.options == nil, @"Already configured");

    if (options.cipherAlgorithm) {
        if ([options.cipherAlgorithm hasSuffix:@"-cbc"]) {
            if (!options.digestAlgorithm) {
                if (error) {
                    *error = OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoAlgorithm);
                }
                return NO;
            }
            CryptoCBC *cbc = [[CryptoCBC alloc] initWithCipherName:options.cipherAlgorithm
                                                        digestName:options.digestAlgorithm
                                                             error:nil];
            if (!cbc) {
                return NO;
            }

            cbc.mappedError = ^NSError *(CryptoCBCError errorCode) {
                switch (errorCode) {
                case CryptoCBCErrorGeneric:
                    return OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoEncryption);

                case CryptoCBCErrorRandomGenerator:
                    return OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoRandomGenerator);

                case CryptoCBCErrorHMAC:
                    return OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoHMAC);
                }
            };

            self.encrypter = cbc;
            self.decrypter = cbc;
        }
        else if ([options.cipherAlgorithm hasSuffix:@"-gcm"]) {
            CryptoAEAD *gcm = [[CryptoAEAD alloc] initWithCipherName:options.cipherAlgorithm
                                                           tagLength:CryptoAEADTagLength
                                                            idLength:CryptoAEADIdLength
                                                               error:nil];
            if (!gcm) {
                return NO;
            }

            gcm.mappedError = ^NSError *(CryptoAEADError errorCode) {
                switch (errorCode) {
                case CryptoAEADErrorGeneric:
                    return OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoEncryption);
                }
            };

            self.encrypter = gcm;
            self.decrypter = gcm;
        }
        else if ([options.cipherAlgorithm hasSuffix:@"-ctr"]) {
            CryptoCTR *ctr = [[CryptoCTR alloc] initWithCipherName:options.cipherAlgorithm
                                                        digestName:options.digestAlgorithm
                                                         tagLength:CryptoCTRTagLength
                                                     payloadLength:CryptoCTRPayloadLength
                                                             error:nil];
            if (!ctr) {
                return NO;
            }

            ctr.mappedError = ^NSError *(CryptoCTRError errorCode) {
                switch (errorCode) {
                case CryptoCTRErrorGeneric:
                    return OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoEncryption);

                case CryptoCTRErrorHMAC:
                    return OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoHMAC);
                }
            };

            self.encrypter = ctr;
            self.decrypter = ctr;
        }
        // not supported
        else {
            if (error) {
                *error = OpenVPNErrorWithCode(OpenVPNErrorCodeCryptoAlgorithm);
            }
            return NO;
        }
    }
    else {
        CryptoCBC *cbc = [[CryptoCBC alloc] initWithCipherName:nil
                                                    digestName:options.digestAlgorithm
                                                         error:nil];
        if (!cbc) {
            return NO;
        }
        self.encrypter = cbc;
        self.decrypter = cbc;
    }
    
    [self.encrypter configureEncryptionWithCipherKey:options.cipherEncKey hmacKey:options.hmacEncKey];
    [self.decrypter configureDecryptionWithCipherKey:options.cipherDecKey hmacKey:options.hmacDecKey];

    NSAssert(self.encrypter.digestLength == self.decrypter.digestLength, @"Digest length mismatch in encrypter/decrypter");

    self.options = options;

    return YES;
}

#pragma mark Implementation

- (NSString *)version
{
    return [NSString stringWithCString:OpenSSL_version(OPENSSL_VERSION) encoding:NSASCIIStringEncoding];
}

- (NSInteger)digestLength
{
    return self.encrypter.digestLength;
}

- (NSInteger)tagLength
{
    return self.encrypter.tagLength;
}

- (BOOL)hmacWithDigestName:(NSString *)digestName
                    secret:(const uint8_t *)secret
              secretLength:(NSInteger)secretLength
                      data:(const uint8_t *)data
                dataLength:(NSInteger)dataLength
                      hmac:(uint8_t *)hmac
                hmacLength:(NSInteger *)hmacLength
                     error:(NSError **)error
{
    NSParameterAssert(digestName);
    NSParameterAssert(secret);
    NSParameterAssert(data);
    
    unsigned int l = 0;

    const BOOL success = HMAC(EVP_get_digestbyname([digestName cStringUsingEncoding:NSASCIIStringEncoding]),
                              secret,
                              (int)secretLength,
                              data,
                              dataLength,
                              hmac,
                              &l) != NULL;

    *hmacLength = l;

    return success;
}

@end
