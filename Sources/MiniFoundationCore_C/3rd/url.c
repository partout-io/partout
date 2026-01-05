#include "url.h"

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

#ifdef NDEBUG
#define ASSERT(x) {}
#else
#define ASSERT(x) { if (!(x)) __builtin_trap(); }
#endif

#define UINT8_MAX  (URL_u8)  ((1 <<  8)-1)
#define UINT16_MAX (URL_u16) ((1 << 16)-1)

#define NULL ((void*) 0)
#define S(X) ((URL_String) { (X), sizeof(X)-1 })
#define EMPTY (URL_String) { NULL, 0 }
#define SLICE(src, off, end) (URL_String) { src + off, end - off }

#if defined(__GNUC__) || defined(__clang__)
#define memcpy_ __builtin_memcpy
#else
static void memcpy_(char *dst, char *src, int len)
{
    for (int i = 0; i < len; i++)
        dst[i] = src[i];
}
#endif

static URL_b32 streq(URL_String a, URL_String b)
{
    if (a.len != b.len)
        return 0;
    for (int i = 0; i < a.len; i++)
        if (a.ptr[i] != b.ptr[i])
            return 0;
    return 1;
}

static char to_lower(char c)
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A' + 'a';
    return c;
}

static URL_b32 streqcase(URL_String a, URL_String b)
{
    if (a.len != b.len)
        return 0;
    for (int i = 0; i < a.len; i++)
        if (to_lower(a.ptr[i]) != to_lower(b.ptr[i]))
            return 0;
    return 1;
}

static URL_b32 is_alpha(char c)
{
    return (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z');
}

static URL_b32 is_digit(char c)
{
    return c >= '0' && c <= '9';
}

static URL_b32 is_hex_digit(char c)
{
    return (c >= '0' && c <= '9')
        || (c >= 'a' && c <= 'f')
        || (c >= 'A' && c <= 'F');
}

#if 0
static URL_b32 is_gen_delim(char c)
{
    return c == ':'
        || c == '/'
        || c == '?'
        || c == '#'
        || c == '['
        || c == ']'
        || c == '@';
}
#endif

static URL_b32 is_sub_delim(char c)
{
    return c == '!'
        || c == '$'
        || c == '&'
        || c == '\''
        || c == '('
        || c == ')'
        || c == '*'
        || c == '+'
        || c == ','
        || c == ';'
        || c == '=';
}

#if 0
static URL_b32 is_reserved(char c)
{
    return is_gen_delim(c)
        || is_sub_delim(c);
}
#endif

static URL_b32 is_unreserved(char c)
{
    return is_alpha(c)
        || is_digit(c)
        || c == '-'
        || c == '.'
        || c == '_'
        || c == '~';
}

static URL_b32 is_scheme_first(char c)
{
    return is_alpha(c);
}

static URL_b32 is_scheme(char c)
{
    return is_alpha(c)
        || is_digit(c)
        || c == '+'
        || c == '-'
        || c == '.';
}

static URL_b32 is_userinfo(char c)
{
    return is_unreserved(c)
        || is_sub_delim(c);
}

static URL_b32 is_reg_name(char c)
{
    return is_unreserved(c)
        || is_sub_delim(c);
}

static URL_b32 is_pchar(char c)
{
    return is_unreserved(c)
        || is_sub_delim(c)
        || c == ':'
        || c == '@';
}

static URL_b32 is_query(char c)
{
    return is_pchar(c)
        || c == '/'
        || c == '?';
}

static URL_b32 is_fragment(char c)
{
    return is_pchar(c)
        || c == '/'
        || c == '?';
}

// Returns 1 if a percent encoded character is
// at offset "cur" and 0 otherwise. If a '%'
// character is found but the following characters
// aren't hex, -1 is returned.
static int is_percent_encoded(char *src, int len, int cur)
{
    if (cur == len || src[cur] != '%')
        return 0;

    if (len - cur <= 2
        || !is_hex_digit(src[cur+1])
        || !is_hex_digit(src[cur+2]))
        return -1;

    return 1;
}

int url_parse_ipv4(char *src, int len, int *pcur, URL_IPv4 *out)
{
    int cur = pcur ? *pcur : 0;

    out->data = 0;
    for (int i = 0; i < 4; i++) {

        if (cur == len || !is_digit(src[cur]))
            return -1;

        URL_u8 byte = src[cur] - '0';
        cur++;

        while (cur < len && is_digit(src[cur])) {

            int n = src[cur] - '0';
            cur++;

            if (byte > (UINT8_MAX - n) / 10)
                return -1;
            byte = byte * 10 + n;
        }

        if (i < 3) {
            if (cur == len || src[cur] != '.')
                return -1;
            cur++;
        }

        out->data <<= 8;
        out->data |= byte;
    }

    if (pcur) {
        *pcur = cur;
    } else {
        if (cur != len)
            return -1;
    }
    return 0;
}

static int hex_digit_to_int(char c)
{
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return c - '0';
}

static int
parse_ipv6_comp(char *src, int len, int *pcur)
{
    int cur = pcur ? *pcur : 0;

    unsigned short buf;

    if (cur == len || !is_hex_digit(src[cur]))
        return -1;
    buf = hex_digit_to_int(src[cur]);
    cur++;

    if (cur == len || !is_hex_digit(src[cur]))
        goto success;
    buf <<= 4;
    buf |= hex_digit_to_int(src[cur]);
    cur++;

    if (cur == len || !is_hex_digit(src[cur]))
        goto success;
    buf <<= 4;
    buf |= hex_digit_to_int(src[cur]);
    cur++;

    if (cur == len || !is_hex_digit(src[cur]))
        goto success;
    buf <<= 4;
    buf |= hex_digit_to_int(src[cur]);
    cur++;

success:
    if (pcur) *pcur = cur;
    return buf;
}

int url_parse_ipv6(char *src, int len, int *pcur, URL_IPv6 *out)
{
    int cur = pcur ? *pcur : 0;

    URL_u16 head[8];
    URL_u16 tail[8];
    int head_len = 0;
    int tail_len = 0;

    if (len - cur > 1
        && src[cur+0] == ':'
        && src[cur+1] == ':')
        cur += 2;
    else {
        for (;;) {

            int ret = parse_ipv6_comp(src, len, &cur);
            if (ret < 0)
                return ret;

            head[head_len++] = (URL_u16) ret;
            if (head_len == 8)
                break;

            if (cur == len || src[cur] != ':')
                return -1;
            cur++;

            if (cur < len && src[cur] == ':') {
                cur++;
                break;
            }
        }
    }

    if (head_len < 8) {
        while (cur < len && is_hex_digit(src[cur])) {

            int ret = parse_ipv6_comp(src, len, &cur);
            if (ret < 0)
                return ret;

            tail[tail_len++] = (URL_u16) ret;
            if (head_len + tail_len == 8)
                break;

            if (cur == len || src[cur] != ':')
                break;
            cur++;
        }
    }

    for (int i = 0; i < head_len; i++)
        out->data[i] = head[i];

    for (int i = 0; i < 8 - head_len - tail_len; i++)
        out->data[head_len + i] = 0;

    for (int i = 0; i < tail_len; i++)
        out->data[8 - tail_len + i] = tail[i];

    if (pcur) {
        *pcur = cur;
    } else {
        if (cur != len)
            return -1;
    }
    return 0;
}

static URL_b32 is_special_scheme(URL_String scheme)
{
    return streqcase(scheme, S("ftp"))
        || streqcase(scheme, S("file"))
        || streqcase(scheme, S("http"))
        || streqcase(scheme, S("https"))
        || streqcase(scheme, S("ws"))
        || streqcase(scheme, S("wss"));
}

int url_parse(char *src, int len, int *pcur, URL *out, int flags)
{
    int cur = pcur ? *pcur : 0;

    out->flags = flags;

    // Parse scheme characters until the end of the string,
    // a character not allowed in the scheme, or ':'. If the
    // found character wasn't ':', set the scheme to empty
    // and rollback the cursor.
    out->scheme = EMPTY;
    if (cur < len && is_scheme_first(src[cur])) {

        // Save the index of the first character of the scheme
        // and advance
        int off = cur;
        cur++;

        // Consume characters from the body of the scheme
        while (cur < len && is_scheme(src[cur]))
            cur++;

        if (cur == len || src[cur] != ':') {
            cur = 0; // Not a scheme after all
        } else {
            out->scheme = SLICE(src, off, cur);
            cur++; // Consume the ':'
        }
    }

    // If the user doesn't allow references and we didn't
    // find a scheme, we fail.
    if ((flags & URL_FLAG_ALLOWREF) == 0 && out->scheme.len == 0)
        return -1;

    // If the following characters are // we expect an
    // authority. An authority consists of some optional
    // userinfo, a domain name, and a port.
    //
    //   scheme://user:pass@domain.com:port...
    //
    // We won't know whether the first portion is user
    // info or the domain until we hit a @ character or
    // a character not allowed in the user info, se we
    // need to backtrack in a similar way to the scheme
    int authority_off = cur;
    out->no_authority = 1;
    out->no_userinfo = 1;
    if (len - cur > 1 && src[cur] == '/' && src[cur+1] == '/') {
        cur += 2; // Consume the //
        out->no_authority = 0;
    } else {
        // The WHATWG standard has a special case for special
        // schemes (ftp, http, https, ...) where if a scheme
        // if followed by a single "/", it behaves like "//".
        //
        // TODO: This rule does not apply if there is a base
        //       URL with a proper authority. Unfortunately,
        //       we don't have access to base URL information
        //       at this point.
        if ((flags & URL_FLAG_RFC3986) == 0) {
            if (is_special_scheme(out->scheme) && !streqcase(out->scheme, S("file")) && cur < len && src[cur] == '/') {
                cur++;
                out->no_authority = 0;
            }
        }
    }

    if (!out->no_authority) {
        out->username = EMPTY;
        out->password = EMPTY;
        if (cur < len && (is_userinfo(src[cur]) || src[cur] == ':')) {

            int user_off = cur;

            while (cur < len) {
                if (is_userinfo(src[cur]))
                    cur++;
                else {
                    int ret = is_percent_encoded(src, len, cur);
                    if (ret < 0)
                        return ret;
                    if (ret == 0)
                        break;
                    cur += 3;
                }
            }

            if (cur < len && src[cur] == ':') {

                cur++; // Consume the ':'
                int pass_off = cur;

                while (cur < len) {
                    if (is_userinfo(src[cur]))
                        cur++;
                    else {
                        int ret = is_percent_encoded(src, len, cur);
                        if (ret < 0)
                            return ret;
                        if (ret == 0)
                            break;
                        cur += 3;
                    }
                }

                if (cur == len || src[cur] != '@') {
                    cur = user_off; // Not userinfo after all
                } else {
                    out->no_userinfo = 0;
                    out->username = SLICE(src, user_off, pass_off-1);
                    out->password = SLICE(src, pass_off, cur);
                    cur++; // Consume the '@'
                }

            } else if (cur < len && src[cur] == '@') {
                out->no_userinfo = 0;
                out->username = SLICE(src, user_off, cur);
                out->password = EMPTY;
                 cur++; // Consume the '@'
            } else {
                cur = user_off; // Not userinfo
            }
        }

        // The domain may be a registered name, an IPv4 address,
        // or an IPv6 address.
        //   example.com
        //   127.0.0.1
        //   [abcd:abcd::0001]
        // Note that an IPv4 could technically be parsed as a
        // registered name, so it's important that we first try
        // the IPv4 rule, and then the registered name rule.
        int host_off = cur;
        if (cur < len && src[cur] == '[') {
            cur++; // Consume the '['

            // We started with an '[', so it's definitely an IPv6
            out->host_type = URL_HOST_IPV6;

            int ret = url_parse_ipv6(src, len, &cur, &out->host_ipv6);
            if (ret < 0)
                return ret;

            if (cur == len || src[cur] != ']')
                return -1; // Missing ']' after IPv6
            cur++;

        } else {

            URL_b32 is_ipv4 = 0;

            // First, try the IPv4 rule
            if (cur < len && is_digit(src[cur])) {
                if (url_parse_ipv4(src, len, &cur, &out->host_ipv4) == 0) {
                    // If we managed to parse an IPv4 address but the
                    // following character si a valid character for a
                    // registered name, then it wasn't an IPv4 after
                    // all. For instance this should not be parsed as
                    // an IPv4:
                    //     127.0.0.1.com
                    if (cur == len || !is_reg_name(src[cur])) {
                        out->host_type = URL_HOST_IPV4;
                        is_ipv4 = 1;
                    }
                }

                if (!is_ipv4)
                    cur = host_off;
            }

            if (!is_ipv4) {
                if (cur < len && (is_reg_name(src[cur]) || is_percent_encoded(src, len, cur) == 1)) {

                    int ret = is_percent_encoded(src, len, cur);
                    ASSERT(ret >= 0);
                    cur += (ret == 1) ? 3 : 1;

                    out->host_type = URL_HOST_NAME;

                    while (cur < len) {
                        if (is_reg_name(src[cur]))
                            cur++;
                        else {
                            int ret = is_percent_encoded(src, len, cur);
                            if (ret < 0)
                                return ret;
                            if (ret == 0)
                                break;
                            cur += 3;
                        }
                    }
                    ASSERT(cur > 0);

                    // Registered names are not allowed to end with a dot,
                    // so unconsume the last character if it is one
                    //
                    // TODO: What if the dot is percent-encoded?
                    if (src[cur-1] == '.')
                        cur--;
                } else {
                    out->host_type = URL_HOST_EMPTY;
                }
            }
        }
        out->host_text = SLICE(src, host_off, cur);

        // Now we parse the port
        out->no_port = 1;
        out->port    = 0;
        if (cur < len && src[cur] == ':') {
            cur++; // Consume the ':'

            if (cur < len && is_digit(src[cur])) {

                // The WHATWG standard forbids port numbers with the
                // "file" protocol.
                if ((flags & URL_FLAG_RFC3986) == 0) {
                    if (streqcase(out->scheme, S("file")))
                        return -1;
                }

                out->no_port = 0;
                do {
                    int n = src[cur] - '0';
                    cur++;

                    if (out->port > (UINT16_MAX - n) / 10)
                        return -1; // Overflow
                    out->port = out->port * 10 + n;
                } while (cur < len && is_digit(src[cur]));
            }
        }

        // The WHATWG standard considers the sequence "//"
        // part of the path and not the authority if userinfo,
        // host, and port are missing
        if ((flags & URL_FLAG_RFC3986) == 0) {
            if ((streqcase(out->scheme, S("http")) || streqcase(out->scheme, S("https")))
                && out->username.len == 0
                && out->password.len == 0
                && out->host_type == URL_HOST_EMPTY
                && out->no_port) {
                out->no_authority = 1;
                cur = authority_off;
            }
        }

    } else {
        out->username = EMPTY;
        out->password = EMPTY;
        out->host_text = EMPTY;
        out->host_type = URL_HOST_EMPTY;
        out->port = 0;
        out->no_port = 1;
    }

    // Now we parse the path. This is most difficult
    // component as it changes based on what comes
    // before it.
    //
    // If an URL contains an authority component, it
    // must be absolute or empty.
    if (!out->no_authority && (cur == len || src[cur] != '/')) {
        out->path = EMPTY;
    } else {

        int off = cur;

        while (cur < len) {
            if (is_pchar(src[cur]) || src[cur] == '/')
                cur++;
            else {
                int ret = is_percent_encoded(src, len, cur);
                if (ret < 0)
                    return ret;
                if (ret == 0)
                    break;
                cur += 3;
            }
        }

        out->path = SLICE(src, off, cur);
    }

    // For a subset of protocols, WHATWG sets the default
    // path to "/"
    if ((flags & URL_FLAG_RFC3986) == 0) {
        if (out->path.len == 0 && is_special_scheme(out->scheme))
            out->path = S("/");
    }

    // Consume the query
    out->query = EMPTY;
    if (cur < len && src[cur] == '?') {

        cur++; // Consume '?'
        int off = cur;

        while (cur < len) {
            if (is_query(src[cur]))
                cur++;
            else {
                int ret = is_percent_encoded(src, len, cur);
                if (ret < 0)
                    return ret;
                if (ret == 0)
                    break;
                cur += 3;
            }
        }

        out->query = SLICE(src, off, cur);
    }

    // Consume the fragment
    out->fragment = EMPTY;
    if (cur < len && src[cur] == '#') {

        cur++; // Consume '#'
        int off = cur;

        while (cur < len) {
            if (is_fragment(src[cur]))
                cur++;
            else {
                int ret = is_percent_encoded(src, len, cur);
                if (ret < 0)
                    return ret;
                if (ret == 0)
                    break;
                cur += 3;
            }
        }

        out->fragment = SLICE(src, off, cur);
    }

    // If a cursor pointer was provided, it is assumed
    // the caller is parsing a string that contains an
    // URL and may be followed by something else, therefore
    // we allow partially parsing the source. If no cursor
    // pointer was provided, we expect the source to be
    // an exact URL string.
    if (pcur) {
        *pcur = cur;
    } else {
        if (cur != len)
            return -1;
    }
    return 0;
}

#define PATH_COMPONENT_LIMIT 32

typedef struct {
    int count;
    URL_b32 first_slash;
    URL_b32 trailing_slash;
    URL_String stack[PATH_COMPONENT_LIMIT];
} PathComps;

static int
resolve_dots_and_append_comps(PathComps *comps, URL_String src)
{
    if (src.len == 0)
        return 0;

    if (src.len > 0 && src.ptr[0] == '/') {
        if (comps->count == 0)
            comps->first_slash = 1;
        src.ptr++;
        src.len--;
    }

    int i = 0;
    for (;;) {

        int off = i;
        while (i < src.len && src.ptr[i] != '/')
            i++;
        int len = i - off;

        URL_String comp = { src.ptr + off, len };
        if (streq(comp, S(".."))) {
            if (comps->count > 0)
                comps->count--;
        } else {
            if (!streq(comp, S("."))) {
                if (comps->count == PATH_COMPONENT_LIMIT)
                    return -1; // To many components
                comps->stack[comps->count++] = comp;
            }
        }

        if (i == src.len)
            break;

        ASSERT(src.ptr[i] == '/');
        i++;

        if (i == src.len)
            break;
    }

    comps->trailing_slash = (src.len > 0 && src.ptr[src.len-1] == '/');
    return 0;
}

typedef struct {
    char *dst;
    int   cap;
    int   len;
} Builder;

static void append(Builder *b, URL_String s)
{
    int unused = b->cap - b->len;
    if (unused > 0) {
        int copy = s.len;
        if (copy > unused)
            copy = unused;
        memcpy_(b->dst + b->len, s.ptr, copy);
    }
    b->len += s.len;
}

static void append_port(Builder *b, URL_u16 port)
{
    char buf[sizeof("65536")-1];
    URL_u16 magn = 10000;
    for (int i = 0; i < 5; i++) {
        buf[i] = '0' + (port / magn);
        port %= magn;
        magn /= 10;
    }

    // Remove leading zeros
    char *ptr = buf;
    while (ptr < buf + sizeof(buf)-1 && *ptr == '0')
        ptr++;

    append(b, (URL_String) { ptr, 5 - (ptr - buf) });
}

static void append_authority(Builder *b, URL url)
{
    if (!url.no_authority) {
        append(b, S("//"));
        if (!url.no_userinfo) {
            append(b, url.username);
            append(b, S(":"));
            append(b, url.password);
            append(b, S("@"));
        }
        append(b, url.host_text);
        if (!url.no_port) {
            append(b, S(":"));
            append_port(b, url.port);
        }
    }
}

static void append_scheme(Builder *b, URL_String scheme)
{
    ASSERT(scheme.len > 0);
    append(b, scheme); // TODO: normalize
    append(b, S(":"));
}

static void append_query(Builder *b, URL_String query)
{
    if (query.len > 0) {
        append(b, S("?"));
        append(b, query);
    }
}

static void append_fragment(Builder *b, URL_String fragment)
{
    if (fragment.len > 0) {
        append(b, S("#"));
        append(b, fragment);
    }
}

int url_serialize(URL url, URL *base, char *dst, int cap)
{
    if (base != NULL && base->scheme.len == 0)
        return -1; // Base is not an absolute URL

    if ((url.flags & URL_FLAG_RFC3986) == 0) {
        if (base
            && streqcase(url.scheme, base->scheme)
            && is_special_scheme(url.scheme)
            && url.no_authority) {
            url.scheme = EMPTY;
        }
    }

    Builder b = { dst, cap, 0 };
    if (url.scheme.len > 0) {
        append_scheme(&b, url.scheme);
        append_authority(&b, url);
        PathComps comps = {0};
        if (resolve_dots_and_append_comps(&comps, url.path) < 0)
                return -1;
        for (int i = 0; i < comps.count; i++) {
            if (i > 0 || comps.first_slash)
                append(&b, S("/"));
            append(&b, comps.stack[i]);
        }
        if (comps.trailing_slash)
            append(&b, S("/"));
        append_query(&b, url.query);
    } else {
        if (base == NULL) {
            // No base URL provided, which means the
            // source is required to be an absolute URL
            return -1;
        }
        ASSERT(base->scheme.len > 0);
        append_scheme(&b, base->scheme);
        if (!url.no_authority) {
            append_authority(&b, url);
            PathComps comps = {0};
            if (resolve_dots_and_append_comps(&comps, url.path) < 0)
                    return -1;
            for (int i = 0; i < comps.count; i++) {
                if (i > 0 || comps.first_slash)
                    append(&b, S("/"));
                append(&b, comps.stack[i]);
            }
            if (comps.trailing_slash)
                append(&b, S("/"));
            append_query(&b, url.query);
        } else {
            append_authority(&b, *base);
            if (url.path.len == 0) {
                append(&b, base->path);
                if (url.query.len > 0) {
                    append_query(&b, url.query);
                } else {
                    append_query(&b, base->query);
                }
            } else {
                ASSERT(url.path.len > 0);
                PathComps comps = {0};
                if (url.path.ptr[0] == '/') {
                    if (resolve_dots_and_append_comps(&comps, url.path) < 0)
                        return -1;
                } else {
                    if (!base->no_authority && base->path.len == 0) {
                        if (resolve_dots_and_append_comps(&comps, url.path) < 0)
                            return -1;
                    } else {
                        if (resolve_dots_and_append_comps(&comps, base->path) < 0)
                                return -1;
                        if (comps.count > 0) {
                            comps.count--;
                        }
                        if (resolve_dots_and_append_comps(&comps, url.path) < 0)
                            return -1;
                    }
                }
                for (int i = 0; i < comps.count; i++) {
                    if (i > 0 || comps.first_slash)
                        append(&b, S("/"));
                    append(&b, comps.stack[i]);
                }
                if (comps.trailing_slash)
                    append(&b, S("/"));
                append_query(&b, url.query);
            }
        }
    }
    append_fragment(&b, url.fragment);

    return b.len;
}

static URL_b32 is_white_space(char c)
{
    return c == ' '
        || c == '\n'
        || c == '\t'
        || c == '\r';
}

int url_remove_white_space(char *src, int len, char *dst, int cap)
{
    while (len > 0 && is_white_space(src[0])) {
        src++;
        len--;
    }

    while (len > 0 && is_white_space(src[len-1]))
        len--;

    int copied = 0;
    for (int i = 0; i < len; i++) {
        if (!is_white_space(src[i]) || src[i] == ' ') {
            if (copied < cap)
                dst[copied] = src[i];
            copied++;
        }
    }

    return copied;
}

int url_percent_decode(URL_String str, char *dst, int cap)
{
    char *src = str.ptr;
    int   len = str.len;
    int   rd  = 0;
    int   wr  = 0;

    while (rd < len) {

        int ret = is_percent_encoded(src, len, rd);
        if (ret < 0)
            return -1;

        char c;
        if (ret == 1) {
            int h = hex_digit_to_int(src[rd+1]);
            int l = hex_digit_to_int(src[rd+2]);
            c = (char) ((h << 4) | l);
            rd += 3;
        } else {
            c = src[rd];
            rd++;
        }

        if (wr < cap)
            dst[wr] = c;
        wr++;
    }
    return wr;
}
