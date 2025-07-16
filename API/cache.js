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

import { api, mockApi, allProviders } from "./lib/api.js";
import { fetchInfrastructure } from "./lib/context.js";
import { mkdir, writeFile } from "fs/promises";

const isRemote = process.argv[2] == 1; // local by default
const cachedIds = process.env.CACHE_IDS ? process.env.CACHE_IDS.split(",") : [];

async function cacheProvidersInParallel(ids) {
    try {
        const writePromises = ids
            .map(async providerId => {
                const providerPath = `cache/${api.root}/${api.version}/providers/${providerId}`;
                await mkdir(providerPath, { recursive: true });
                const dest = `${providerPath}/fetch.json`;
                const options = {
                    forCache: true,
                    responseOnly: true
                };
                const json = fetchInfrastructure(isRemote ? api : mockApi, providerId, options);
                const minJSON = JSON.stringify(json);
                return writeFile(dest, minJSON, "utf8");
            });

        await Promise.all(writePromises);

        console.log("All files written successfully");
    } catch (error) {
        console.error("Error writing files:", error);
    }
}

// opt out
//const targetIds = allProviders(".")
//    .filter(id => !cachedIds.has(id));

// opt in
const targetIds = cachedIds;

await cacheProvidersInParallel(targetIds);
