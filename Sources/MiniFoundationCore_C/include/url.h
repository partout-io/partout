#ifndef URL_INCLUDED
#define URL_INCLUDED
// This is free and unencumbered software released into the public domain.
//
// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.
//
// In jurisdictions that recognize copyright laws, the author or authors
// of this software dedicate any and all copyright interest in the
// software to the public domain. We make this dedication for the benefit
// of the public at large and to the detriment of our heirs and
// successors. We intend this dedication to be an overt act of
// relinquishment in perpetuity of all present and future rights to this
// software under copyright law.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//
// For more information, please refer to <https://unlicense.org>

typedef unsigned char  URL_u8;
typedef unsigned short URL_u16;
typedef unsigned int   URL_u32;
typedef unsigned int   URL_b32;

typedef struct {
    char *ptr;
    int   len;
} URL_String;

typedef struct { URL_u32 data;    } URL_IPv4;
typedef struct { URL_u16 data[8]; } URL_IPv6;

typedef enum {
    URL_HOST_EMPTY,
    URL_HOST_IPV4,
    URL_HOST_IPV6,
    URL_HOST_NAME,
} URL_HostType;

typedef struct {

    // Flags used to parse this URL
    int flags;

    // These flags are used to differentiate between
    // an empty userinfo/authority and an undefined one.
    // For instance:
    //     http:index.html      URL with no authority
    //     http:///index.html   URL with an empty authority
    //     http://example.com   URL with no userinfo
    //     http://:@example.com URL with an empty userinfo
    // We keep track of this in case we want to encode
    // back the parsed URL.
    URL_b32 no_authority;
    URL_b32 no_userinfo;

    // Can only be empty when URL_FLAG_ALLOWREF is passed
    // to url_parse.
    URL_String scheme;

    // Both may be empty
    // May be percent-encoded
    URL_String username;
    URL_String password;

    // The raw host string is stored in host_text.
    // If the host is an IPv4 or IPv6, its parsed
    // value is also stored in host_ipv4 or host_ipv6
    // (host byte order).
    // Note that the host may be empty, in which
    // case host_type=URL_HOST_EMPTY.
    // If host_text is set, it may be percent-encoded.
    URL_HostType host_type;
    URL_String   host_text;
    union {
        URL_IPv4 host_ipv4;
        URL_IPv6 host_ipv6;
    };

    // If no port was specified, no_port is set
    // to 1 and port to 0.
    URL_b32 no_port;
    URL_u16 port;

    // May be percent-encoded
    URL_String path;

    // May be empty
    // May be percent-encoded
    URL_String query;

    // May be empty
    // May be percent-encoded
    URL_String fragment;

} URL;

// Parse an IPv4 in dotted-decimal notation (127.0.0.1)
// If pcur is not NULL, parsing starts at offset *pcur
// and the final cursor state is written back into pcur.
// If pcur is NULL, the string is assumed to only contain
// the IPv4 address, so the function fails if the string
// contains anything else after it.
int url_parse_ipv4(char *src, int len, int *pcur, URL_IPv4 *out);

// Like url_parse_ipv4, but for IPv6 addresses.
int url_parse_ipv6(char *src, int len, int *pcur, URL_IPv6 *out);

enum {
    URL_FLAG_ALLOWREF = 1<<0,
    URL_FLAG_RFC3986  = 1<<1,
};

// Parses the URL contained in the string "src" of length "len"
// into the structure "out". The output structure will hold
// references to the input buffer. Any percent-encoded components
// are validated but not converted. The percent-decoded version
// of a component can be obtained by calling url_percent_decode.
//
// If "pcur" is not null, the parsing will start at offset *pcur
// and the final position of the cursor will be stored back in
// pcur. If pcur is NULL, the string is expected to only contain
// the URL, so the function fails if the string contains something
// other than the URL.
//
// If "flags" is zero, the function will parse URLs according
// to the WHATWG specification (which is what browsers actually
// do). Strictly speaking, to adhere to WHATWG the parser needs
// to strip whitespace from the URL before processing it, which
// this function doesn't do. If you want this behavior, you must
// preprocess the input with url_remove_white_space.
//
// If the flag URL_FLAG_RFC3986 is passed, the parser will strictly
// adhere to RFC 3986.
//
// If the flag URL_FLAG_ALLOWREF is passed, then relative
// references may also be parsed. These include things like
// "../index.html", which are not URLs but may be evaluated as
// such in relation to one. Relative references may be resolved
// using url_serialize.
int url_parse(char *src, int len, int *pcur, URL *out, int flags);

// Remove whitespace from the string "src" of length "len"
// according to the WHATWG specification. Using this function
// alongside url_parse has the same behavior to what browsers
// do.
// The result string is written to the buffer "dst" of capacity
// "cap". If the buffer isn't large enough, the number of bytes
// that would have been written is returned.
int url_remove_white_space(char *src, int len, char *dst, int cap);

// Percent-decodes the string "str" into the buffer "dst" of
// capacity "cap". If the buffer's capacity wasn't enough, the
// number of bytes that would have been written is returned.
// If the string wasn't percent-encoded (% characters not followed
// by valid hex digits), -1 is returned.
int url_percent_decode(URL_String str, char *dst, int cap);

// Serializes "url" into the buffer "dst" of capacity "cap".
// If the capacity wasn't enough, the number of bytes that
// would have been written is returned.
// If "url" is a relative reference, then it is resolved
// against the absolute URL "base", which can otherwite be
// set to NULL.
// Note that this can be used to normalize an URL, even
// though it's just a best-effor normalization for now.
int url_serialize(URL url, URL *base, char *dst, int cap);

#endif // URL_INCLUDED
