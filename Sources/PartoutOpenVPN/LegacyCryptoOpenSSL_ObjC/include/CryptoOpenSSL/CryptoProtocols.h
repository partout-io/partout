/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

@class ZeroingData;

NS_ASSUME_NONNULL_BEGIN

@protocol Crypto

/// The digest length or 0.
- (int)digestLength;

/// The tag length or 0.
- (int)tagLength;

/// The preferred encryption capacity.
/// - Parameter length: The number of bytes to encrypt.
- (NSInteger)encryptionCapacityWithLength:(NSInteger)length;

@end

@protocol Encrypter <Crypto>

/// Configures the object.
/// - Parameters:
///   - cipherKey: The cipher key data.
///   - hmacKey: The HMAC key data.
- (void)configureEncryptionWithCipherKey:(nullable ZeroingData *)cipherKey hmacKey:(nullable ZeroingData *)hmacKey;

/// Encrypts a buffer.
/// - Parameters:
///   - bytes: Bytes to encrypt.
///   - length: The number of bytes.
///   - dest: The destination buffer.
///   - destLength: The number of bytes written to ``dest``.
///   - flags: The optional encryption flags.
- (BOOL)encryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags *_Nullable)flags error:(NSError **)error;

@end

@protocol Decrypter <Crypto>

/// Configures the object.
/// - Parameters:
///   - cipherKey: The cipher key data.
///   - hmacKey: The HMAC key data.
- (void)configureDecryptionWithCipherKey:(nullable ZeroingData *)cipherKey hmacKey:(nullable ZeroingData *)hmacKey;

/// Decrypts a buffer.
/// - Parameters:
///   - bytes: Bytes to decrypt.
///   - length: The number of bytes.
///   - dest: The destination buffer.
///   - destLength: The number of bytes written to ``dest``.
///   - flags: The optional encryption flags.
- (BOOL)decryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags *_Nullable)flags error:(NSError **)error;

/// Verifies an encrypted buffer.
/// - Parameters:
///   - bytes: Bytes to decrypt.
///   - length: The number of bytes.
///   - flags: The optional encryption flags.
- (BOOL)verifyBytes:(const uint8_t *)bytes length:(NSInteger)length flags:(const CryptoFlags *_Nullable)flags error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
