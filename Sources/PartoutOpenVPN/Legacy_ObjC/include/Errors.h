/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

extern NSString *const OpenVPNErrorDomain;
extern NSString *const OpenVPNErrorKey;

typedef NS_ENUM(NSInteger, OpenVPNErrorCode) {
    OpenVPNErrorCodeCryptoRandomGenerator       = 101,
    OpenVPNErrorCodeCryptoHMAC                  = 102,
    OpenVPNErrorCodeCryptoEncryption            = 103,
    OpenVPNErrorCodeCryptoAlgorithm             = 104,
    OpenVPNErrorCodeTLSCARead                   = 201,
    OpenVPNErrorCodeTLSCAUse                    = 202,
    OpenVPNErrorCodeTLSCAPeerVerification       = 203,
    OpenVPNErrorCodeTLSClientCertificateRead    = 204,
    OpenVPNErrorCodeTLSClientCertificateUse     = 205,
    OpenVPNErrorCodeTLSClientKeyRead            = 206,
    OpenVPNErrorCodeTLSClientKeyUse             = 207,
    OpenVPNErrorCodeTLSHandshake                = 210,
    OpenVPNErrorCodeTLSServerCertificate        = 211,
    OpenVPNErrorCodeTLSServerEKU                = 212,
    OpenVPNErrorCodeTLSServerHost               = 213,
    OpenVPNErrorCodeDataPathOverflow            = 301,
    OpenVPNErrorCodeDataPathPeerIdMismatch      = 302,
    OpenVPNErrorCodeDataPathCompression         = 303,
    OpenVPNErrorCodeUnknown                     = 999
};

static inline NSError *OpenVPNErrorWithCode(OpenVPNErrorCode code) {
    return [NSError errorWithDomain:OpenVPNErrorDomain code:code userInfo:nil];
}
