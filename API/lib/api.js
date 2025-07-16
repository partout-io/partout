//
// MIT License
//
// Copyright (c) 2025 Davide De Rosa
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import fs from "fs";

export const api = {
    version: "v7",
    root: "src",
    index: "index.json"
};

export const modes = {
    LOCAL_UNCACHED: null,   // process local mock with full script
    REMOTE_UNCACHED: 1,     // process remote with full script
    PRODUCTION: 2           // process remote with cache script if available (production)
};

export function allProviders(root) {
    const excludedProviders = new Set([]);
    const apiIndex = `${root}/${api.root}/${api.version}/index.json`;
    const data = JSON.parse(fs.readFileSync(apiIndex, "utf8"));
    return data.providers
        .map(provider => provider.id)
        .filter(id => !excludedProviders.has(id));
}
