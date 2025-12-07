/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include <vector>
#include <string>
#include <regex>
#include <assert.h>

struct _minif_rx_match {
    const char *token;
    size_t location;
    size_t length;
};

struct _minif_rx_result {
    _minif_rx_match *matches;
    size_t count;
};

minif_rx_result *minif_rx_groups(const char *pattern, const char *input) {
    if (!pattern || !input) return nullptr;
    try {
        std::regex re(pattern);
        std::cmatch match;
        if (!std::regex_search(input, match, re)) {
            return nullptr;
        }
        minif_rx_result *result = new minif_rx_result;
        result->count = match.size();
        result->matches = new _minif_rx_match[result->count];

        // Copy each matched group into heap-allocated C strings
        for (size_t i = 0; i < match.size(); ++i) {
            const std::string &s = match[i].str();
            char *cstr = new char[s.size() + 1];
            memcpy(cstr, s.c_str(), s.size() + 1);
            result->matches[i].token = cstr;
        }
        return result;
    } catch (const std::regex_error&) {
        return nullptr;
    }
}

minif_rx_result *minif_rx_matches(const char *pattern, const char *input) {
    if (!pattern || !input) return nullptr;
    try {
        std::regex re(pattern);
        std::cmatch match;
        const char *start = input;

        // Find multiple matches over the same string
        std::vector<std::string> collected;
        std::vector<_minif_rx_match> ranges;
        while (std::regex_search(start, match, re)) {
            collected.push_back(match.str(0));
            const _minif_rx_match range = {
                nullptr,
                (size_t)match.position(0) + (start - input),
                (size_t)match.length()
            };
            ranges.push_back(range);
            // Avoid infinite loop on zero-length matches
            if (match.length(0) == 0) {
                // Advance by one UTF-8 byte
                start += 1;
                // Stop if we reached the end
                if (*start == '\0') break;
                continue;
            }
            start = match.suffix().first;
        }
        if (collected.empty()) return nullptr;

        minif_rx_result *out = new minif_rx_result;
        out->count = collected.size();
        out->matches = new _minif_rx_match[out->count];
        for (int i = 0; i < out->count; ++i) {
            const std::string &s = collected[i];
            char* cstr = new char[s.size() + 1];
            memcpy(cstr, s.c_str(), s.size() + 1);
            out->matches[i].token = cstr;
            // Copy from before
            out->matches[i].location = ranges[i].location;
            out->matches[i].length = ranges[i].length;
        }
        return out;
    } catch (const std::regex_error&) {
        return nullptr;
    }
}

void minif_rx_result_free(minif_rx_result *result) {
    if (!result) return;
    if (result->matches) {
        for (int i = 0; i < result->count; ++i) {
            delete[] result->matches[i].token;
        }
        delete[] result->matches;
    }
    delete result;
}

size_t minif_rx_result_get_items_count(const minif_rx_result *result) {
    return result->count;
}

const minif_rx_match *minif_rx_result_get_item(const minif_rx_result *result, int index) {
    assert(index < result->count);
    return &result->matches[index];
}

const char *minif_rx_match_get_token(const minif_rx_match *item) {
    return item->token;
}

size_t minif_rx_match_get_location(const minif_rx_match *item) {
    return item->location;
}

size_t minif_rx_match_get_length(const minif_rx_match *item) {
    return item->length;
}
