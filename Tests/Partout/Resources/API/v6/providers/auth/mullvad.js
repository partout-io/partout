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

/*
 options = {
    credentials: {},
    token: null,
    sessions: {
        device1: {
            privateKey: "",
            publicKey: "",
            peer: {
                clientId: "",
                addresses: []
            }
        },
        device2: { ... }
    }
 }

 credentials = { username, password }
 token = { accessToken, expiryDate }
 session = { privateKey, publicKey, peer: { clientId, addresses } }
 */

//function authenticate(credentials, token, session) {
function authenticate(module, deviceId) {
    const wgType = "WireGuard";
    // FIXME: ###, how to shortcut return N times?
    const defaultResponse = {
        response: module
    };
    if (module.providerModuleType != wgType) {
        return defaultResponse;
    }
    debug(`${JSON.stringify(module)}`);
    debug(`>>> allOptions: ${module.moduleOptions}`);
    const rawOptions = module.moduleOptions[wgType];
    debug(`>>> rawOptions: ${rawOptions}`);
    if (!rawOptions) {
        return defaultResponse;
    }
    const options = jsonFromBase64(rawOptions);
    debug(`>>> options: ${JSON.stringify(options)}`);
    if (!options) {
        return defaultResponse;
    }
    const session = options.sessions[deviceId];
    if (!session) {
        return defaultResponse;
    }

    debug("OLE!");
    debug(JSON.stringify(options));
    debug(JSON.stringify(session));

    // 1. authenticate
    var token = options.token;
    if (token) {// FIXME: ###, check expiry && token.expiryDate > now) {
        // go ahead
    } else if (options.credentials) {
        const body = jsonToBase64({
            "account_number": options.credentials.username
        });
        debug(`>>> body: ${body}`);
        const headers = {"Content-type": "application/json"};
        const json = getResult("POST", "https://api.mullvad.net/auth/v1/token", headers, body);
        if (json.error) {
            return defaultResponse;
        }
        debug(`>>> CREDENTIALS!!! ${json.response}`);
        token = {
            accessToken: json.response.access_token,
            expiryDate: json.response.expiry
        };
    } else {
        return {
            error: "auth"
        }
    }

    // 2. get list of devices to look up own pubkey
    debug(`>>> TOKEN!!! ${JSON.stringify(token)}`);
    const headers = {"Authorization": `Bearer ${token.accessToken}`};
    debug(`>>> headers: ${JSON.stringify(headers)}`);
    const json = getResult("GET", "https://api.mullvad.net/accounts/v1/devices", headers);
    if (json.error) {
        return defaultResponse;
    }
    debug(`>>> devices: ${json.response}`);

    // 3.2. POST if new
//    const keyUrl = "https://api.mullvad.net/accounts/v1/devices";

    // 3.3. PUT if existing
//    const keyUrl = "https://api.mullvad.net/accounts/v1/devices/${session.deviceId}/pubkey";

    const newModule = module;
    return {
        response: newModule
    };
}
