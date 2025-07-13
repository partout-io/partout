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

const baseURL = "https://api.mullvad.net";

//function authenticate(credentials, token, session) {
function authenticate(module, deviceId) {
    const wgType = "WireGuard";
    // FIXME: ###, how to mimic goto failure?
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

    // authenticate
    var token = options.token;
    // FIXME: ###, check token expiration (token.expiryDate > now, 1 day, beware of Apple/UNIX timestamp)
    if (token) {
        // go ahead
    } else if (options.credentials) {
        const body = jsonToBase64({
            "account_number": options.credentials.username
        });
        debug(`>>> body: ${body}`);
        const headers = {"Content-type": "application/json"};
        const json = getResult("POST", `${baseURL}/auth/v1/token`, headers, body);
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

    // get list of devices
    debug(`>>> TOKEN!!! ${JSON.stringify(token)}`);
    const headers = {"Authorization": `Bearer ${token.accessToken}`};
    debug(`>>> headers: ${JSON.stringify(headers)}`);
    const json = getResult("GET", `${baseURL}/accounts/v1/devices`, headers);
    if (json.error) {
        return defaultResponse;
    }
    const devices = JSON.parse(json.response);
    debug(`>>> devices: ${json.response}`);

    // look up own device
    debug(`>>> pubkey: ${session.publicKey}`);

    // look up own pubkey
    const existing = devices.find(d => d.pubkey == session.publicKey);
    if (existing) {
        // read if existing
        // FIXME: ###, PUT to renew
//        const keyUrl = `${baseURL}/accounts/v1/devices/${session.deviceId}/pubkey`;
        debug(`>>> existing: ${JSON.stringify(existing)}`);
        let peer = {
            creationDate: existing.created,
            addresses: []
        };
        if (existing.ipv4_address) {
            peer.addresses.push(existing.ipv4_address);
        }
        if (existing.ipv6_address) {
            peer.addresses.push(existing.ipv6_address);
        }
        session.peer = peer;
        debug(`>>> peer: ${JSON.stringify(session.peer)}`);
    }
    else {
        // FIXME: ###, POST if new
//        const keyUrl = `${baseURL}/accounts/v1/devices`;
    }

    const newModule = module;
    return {
        response: newModule
    };
}
