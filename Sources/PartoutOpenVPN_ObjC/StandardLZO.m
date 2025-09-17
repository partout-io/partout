// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import "StandardLZO.h"
#import "minilzo.h"

NSString *const PassepartoutLZOErrorDomain = @"PassepartoutLZO";

#define HEAP_ALLOC(var,size) \
lzo_align_t __LZO_MMODEL var [ ((size) + (sizeof(lzo_align_t) - 1)) / sizeof(lzo_align_t) ]

#define LZO1X_1_15_MEM_COMPRESS ((lzo_uint32_t) (32768L * lzo_sizeof_dict_t))

static HEAP_ALLOC(wrkmem, LZO1X_1_MEM_COMPRESS);

@interface StandardLZO ()

@property (nonatomic, strong) NSMutableData *decompressedBuffer;

@end

@implementation StandardLZO

+ (NSString *)versionString
{
    return [NSString stringWithCString:lzo_version_string() encoding:NSUTF8StringEncoding];
}

- (instancetype)init
{
    if (lzo_init() != LZO_E_OK) {
        NSCAssert(NO, @"LZO engine failed to initialize");
        abort();
        return nil;
    }
    if ((self = [super init])) {
        self.decompressedBuffer = [[NSMutableData alloc] initWithLength:LZO1X_1_15_MEM_COMPRESS];
    }
    return self;
}

- (NSData *)compressedDataWithData:(NSData *)data error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    const NSInteger dstBufferLength = data.length + data.length / 16 + 64 + 3;
    NSMutableData *dst = [[NSMutableData alloc] initWithLength:dstBufferLength];
    lzo_uint dstLength;
    const int status = lzo1x_1_compress(data.bytes, data.length, dst.mutableBytes, &dstLength, wrkmem);
    if (status != LZO_E_OK) {
        if (error) {
            *error = [NSError errorWithDomain:PassepartoutLZOErrorDomain code:0 userInfo:nil];
        }
        return nil;
    }
    if (dstLength > data.length) {
        return nil;
    }
    dst.length = dstLength;
    return dst;
}

- (NSData *)decompressedDataWithData:(NSData *)data error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    return [self decompressedDataWithBytes:data.bytes length:data.length error:error];
}

- (NSData *)decompressedDataWithBytes:(const uint8_t *)bytes length:(NSInteger)length error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    lzo_uint dstLength = LZO1X_1_15_MEM_COMPRESS;
    const int status = lzo1x_decompress_safe(bytes, length, self.decompressedBuffer.mutableBytes, &dstLength, NULL);
    if (status != LZO_E_OK) {
        if (error) {
            *error = [NSError errorWithDomain:PassepartoutLZOErrorDomain code:0 userInfo:nil];
        }
        return nil;
    }
    return [NSData dataWithBytes:self.decompressedBuffer.bytes length:dstLength];
}

@end
