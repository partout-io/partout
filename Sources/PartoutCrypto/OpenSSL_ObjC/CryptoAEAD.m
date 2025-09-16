// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <openssl/evp.h>

#import "CryptoOpenSSL/Allocation.h"
#import "CryptoOpenSSL/CryptoAEAD.h"
#import "CryptoOpenSSL/CryptoMacros.h"
#import "CryptoOpenSSL/ZeroingData.h"

@interface CryptoAEAD ()

@property (nonatomic, assign) NSInteger nsTagLength;
@property (nonatomic, assign) NSInteger idLength;

@property (nonatomic, unsafe_unretained) const EVP_CIPHER *cipher;
@property (nonatomic, assign) int cipherKeyLength;
@property (nonatomic, assign) int cipherIVLength;

@property (nonatomic, unsafe_unretained) EVP_CIPHER_CTX *cipherCtxEnc;
@property (nonatomic, unsafe_unretained) EVP_CIPHER_CTX *cipherCtxDec;
@property (nonatomic, unsafe_unretained) uint8_t *cipherIVEnc;
@property (nonatomic, unsafe_unretained) uint8_t *cipherIVDec;

@end

@implementation CryptoAEAD

- (nullable instancetype)initWithCipherName:(NSString *)cipherName
                                  tagLength:(NSInteger)tagLength
                                   idLength:(NSInteger)idLength
                                      error:(NSError **)error
{
    NSLog(@"PartoutOpenVPN: Using CryptoAEAD (legacy ObjC)");
    NSParameterAssert([[cipherName uppercaseString] hasSuffix:@"GCM"]);

    self = [super init];
    if (self) {
        self.nsTagLength = tagLength;
        self.idLength = idLength;

        self.cipher = EVP_get_cipherbyname([cipherName cStringUsingEncoding:NSASCIIStringEncoding]);
        NSAssert(self.cipher, @"Unknown cipher '%@'", cipherName);
        if (!self.cipher) {
            return nil;
        }

        self.cipherKeyLength = EVP_CIPHER_key_length(self.cipher);
        self.cipherIVLength = EVP_CIPHER_iv_length(self.cipher);

        self.cipherCtxEnc = EVP_CIPHER_CTX_new();
        self.cipherCtxDec = EVP_CIPHER_CTX_new();
        self.cipherIVEnc = pp_alloc_crypto(self.cipherIVLength);
        self.cipherIVDec = pp_alloc_crypto(self.cipherIVLength);

        self.mappedError = ^NSError *(CryptoAEADError errorCode) {
            return [NSError errorWithDomain:PartoutCryptoErrorDomain code:0 userInfo:nil];
        };
    }
    return self;
}

- (void)dealloc
{
    EVP_CIPHER_CTX_free(self.cipherCtxEnc);
    EVP_CIPHER_CTX_free(self.cipherCtxDec);
    bzero(self.cipherIVEnc, self.cipherIVLength);
    bzero(self.cipherIVDec, self.cipherIVLength);
    free(self.cipherIVEnc);
    free(self.cipherIVDec);

    self.cipher = NULL;
}

- (int)digestLength
{
    return 0;
}

- (int)tagLength
{
    return (int)self.nsTagLength;
}

- (NSInteger)encryptionCapacityWithLength:(NSInteger)length
{
    return pp_alloc_crypto_capacity(length, self.tagLength);
}

#pragma mark Encrypter

- (void)configureEncryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    NSParameterAssert(cipherKey.length >= self.cipherKeyLength);
    NSParameterAssert(hmacKey);

    EVP_CIPHER_CTX_reset(self.cipherCtxEnc);
    EVP_CipherInit(self.cipherCtxEnc, self.cipher, cipherKey.bytes, NULL, 1);

    [self prepareIV:self.cipherIVEnc withHMACKey:hmacKey];
}

- (BOOL)encryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    NSParameterAssert(flags);

    int l1 = 0, l2 = 0;
    int x = 0;
    int code = 1;

    assert(flags->adLength >= self.idLength);
    memcpy(self.cipherIVEnc, flags->iv, MIN(flags->ivLength, self.cipherIVLength));

    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(self.cipherCtxEnc, NULL, NULL, self.cipherIVEnc, -1);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxEnc, NULL, &x, flags->ad, (int)flags->adLength);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxEnc, dest + self.tagLength, &l1, bytes, (int)length);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(self.cipherCtxEnc, dest + self.tagLength + l1, &l2);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CIPHER_CTX_ctrl(self.cipherCtxEnc, EVP_CTRL_GCM_GET_TAG, self.tagLength, dest);

    *destLength = self.tagLength + l1 + l2;

    CRYPTO_OPENSSL_RETURN_STATUS(code, self.mappedError(CryptoAEADErrorGeneric))
}

#pragma mark Decrypter

- (void)configureDecryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    NSParameterAssert(cipherKey.length >= self.cipherKeyLength);
    NSParameterAssert(hmacKey);

    EVP_CIPHER_CTX_reset(self.cipherCtxDec);
    EVP_CipherInit(self.cipherCtxDec, self.cipher, cipherKey.bytes, NULL, 0);

    [self prepareIV:self.cipherIVDec withHMACKey:hmacKey];
}

- (BOOL)decryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    NSParameterAssert(flags);

    int l1 = 0, l2 = 0;
    int x = 0;
    int code = 1;

    assert(flags->adLength >= self.idLength);
    memcpy(self.cipherIVDec, flags->iv, MIN(flags->ivLength, self.cipherIVLength));

    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(self.cipherCtxDec, NULL, NULL, self.cipherIVDec, -1);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CIPHER_CTX_ctrl(self.cipherCtxDec, EVP_CTRL_GCM_SET_TAG, self.tagLength, (uint8_t *)bytes);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxDec, NULL, &x, flags->ad, (int)flags->adLength);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(self.cipherCtxDec, dest, &l1, bytes + self.tagLength, (int)length - self.tagLength);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(self.cipherCtxDec, dest + l1, &l2);

    *destLength = l1 + l2;

    CRYPTO_OPENSSL_RETURN_STATUS(code, self.mappedError(CryptoAEADErrorGeneric))
}

- (BOOL)verifyBytes:(const uint8_t *)bytes length:(NSInteger)length flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    [NSException raise:NSInvalidArgumentException format:@"Verification not supported"];
    return NO;
}

#pragma mark Helpers

- (void)prepareIV:(uint8_t *)iv withHMACKey:(ZeroingData *)hmacKey
{
    bzero(iv, self.idLength);
    memcpy(iv + self.idLength, hmacKey.bytes, self.cipherIVLength - self.idLength);
}

@end
