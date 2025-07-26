// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <Foundation/Foundation.h>

#import "OpenVPNTLSProtocol.h"

const NSInteger OpenVPNTLSOptionsDefaultBufferLength = 16384;
const NSInteger OpenVPNTLSOptionsDefaultSecurityLevel = 0;

@interface OpenVPNTLSOptions ()

@property (nonatomic, assign) NSInteger bufferLength;
@property (nonatomic, strong) NSURL *caURL;
@property (nonatomic, copy) NSString *clientCertificatePEM;
@property (nonatomic, copy) NSString *clientKeyPEM;
@property (nonatomic, assign) BOOL checksEKU;
@property (nonatomic, assign) BOOL checksSANHost;
@property (nonatomic, copy) NSString *hostname;
@property (nonatomic, assign) NSInteger securityLevel;

@end

@implementation OpenVPNTLSOptions

- (instancetype)initWithBufferLength:(NSInteger)bufferLength
                               caURL:(NSURL *)caURL
                clientCertificatePEM:(NSString *)clientCertificatePEM
                        clientKeyPEM:(NSString *)clientKeyPEM
                           checksEKU:(BOOL)checksEKU
                       checksSANHost:(BOOL)checksSANHost
                            hostname:(NSString *)hostname
                       securityLevel:(NSInteger)securityLevel
{
    if ((self = [super init])) {
        self.bufferLength = bufferLength != 0 ? bufferLength : OpenVPNTLSOptionsDefaultBufferLength;
        self.caURL = caURL;
        self.clientCertificatePEM = clientCertificatePEM;
        self.clientKeyPEM = clientKeyPEM;
        self.checksEKU = checksEKU;
        self.checksSANHost = checksSANHost;
        self.hostname = hostname;
        self.securityLevel = securityLevel > OpenVPNTLSOptionsDefaultSecurityLevel ? securityLevel : OpenVPNTLSOptionsDefaultSecurityLevel;
    }
    return self;
}

@end
