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
import vm from "vm";
import request from "sync-request";

function runSandboxedScript(code, injectedFunctions = {}) {
    const sandbox = { api: { ...injectedFunctions } };
    const context = vm.createContext(sandbox);
    return vm.runInContext(code, context);
}

function fetchScriptPath(root, providerId) {
    const name = `${providerId}.js`;
    return `${root}/${name}`;
}

export function fetchInfrastructure(api, providerId, options) {
    const scriptRoot = `${api.root}/${api.version}/providers`;
    const scriptPath = fetchScriptPath(scriptRoot, providerId);
    const optionsCopy = { ...options };
    if (api.mockPath) {
        optionsCopy.mockPath = api.mockPath;
    }
    return fetchRawInfrastructure(scriptPath, optionsCopy);
}

export function fetchRawInfrastructure(scriptPath, options) {
    const script = fs.readFileSync(scriptPath, "utf8");
    const referenceDate = new Date(0); // UNIX epoch

    function getResult(url) {
        if (options.mockPath) {
            const data = fs.readFileSync(options.mockPath, "utf8");
            return {
                data: data
            };
        }
        console.log(`GET ${url}`);
        const response = request("GET", url);
        const data = response.getBody("utf8");
        // console.log(response.headers);
        const lastModified = response.headers["last-modified"];
        const tag = response.headers["etag"];
        const lastUpdate = lastModified ? ((new Date(lastModified) - referenceDate) / 1000.0) : undefined;
        const cache = {
            lastUpdate: lastUpdate,
            tag: tag
        };
        return {
            data: data,
            cache: cache
        };
    }

    const injectedFunctions = {
        getText(url) {
            const result = getResult(url);
            return {
                response: result.data,
                cache: result.cache
            };
        },
        getJSON(url) {
            const result = getResult(url);
            const json = JSON.parse(result.data);
            return {
                response: json,
                cache: result.cache
            };
        },
        jsonToBase64(object) {
            try {
                const jsonString = JSON.stringify(object);
                return Buffer.from(jsonString).toString("base64");
            } catch (error) {
                console.error(`JS.jsonToBase64: Unable to serialize: ${error}`);
                return null;
            }
        },
        ipV4ToBase64(ip) {
            const bytes = ip.split(".").map(Number);
            if (bytes.length !== 4 || bytes.some(isNaN)) {
                console.error("JS.ipV4ToBase64: Not a valid IPv4 string");
                return null;
            }
            return Buffer.from(bytes).toString("base64");
        },
        openVPNTLSWrap(strategy, file) {
            const hex = file.trim().split("\n").join("");
            const key = Buffer.from(hex, "hex");
            if (key.length !== 256) {
                console.error("JS.openVPNTLSWrap: Static key must be 32 bytes long");
                return null;
            }
            return {
                strategy: strategy,
                key: {
                    dir: 1,
                    data: key.toString("base64")
                }
            };
        },
        debug(message) {
            console.error(message);
        }
    };

    const fromCache = options.fromCache ?? true;
    const wrappedScript = `
        ${script}
        getInfrastructure({}, ${fromCache});
    `;
    const json = runSandboxedScript(wrappedScript, injectedFunctions);
    if (options.responseOnly) {
        return json.response;
    }
    return json;
}
