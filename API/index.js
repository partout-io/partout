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

import { api, modes } from "./lib/api.js";
import { fetchInfrastructure, fetchRawInfrastructure } from "./lib/context.js";

const target = process.argv[2];
const mode = process.argv[3];
if (!target) {
    console.error("Please provide a provider ID or a file.js");
    process.exit(1);
}

let json;
const options = {
    preferCache: mode == modes.PRODUCTION
};
if (target.endsWith(".js")) {
    const filename = target;
    json = fetchRawInfrastructure(target, options);
} else {
    const providerId = target;
    if (mode == modes.LOCAL_UNCACHED) {
        options.responsePath = `test/mock/providers/${providerId}/fetch.json`;
    }
    json = fetchInfrastructure(api, providerId, options);
}
console.log(JSON.stringify(json, null, 2));
