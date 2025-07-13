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
    credentials: { username, password },
    token: { accessToken, expiryDate },
    sessions: {
        device1: {
            privateKey: "",
            publicKey: "",
            peer: {
                id: "",
                creationDate: ...,
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
    const storage = jsonFromBase64(rawOptions);
    debug(`>>> storage: ${JSON.stringify(storage)}`);
    if (!storage) {
        return defaultResponse;
    }
    const session = storage.sessions[deviceId];
    if (!session) {
        return defaultResponse;
    }

    debug("OLE!");
    debug(JSON.stringify(storage));
    debug(JSON.stringify(session));

    // check token expiry
    if (storage.token) {
        const expiry = new Date(timestampToISO(storage.token.expiryDate));
        const now = new Date();
        debug(`>>> expiry: ${expiry}`);
        debug(`>>> now: ${now}`);
        if (expiry > now) {
            debug(`>>> token is valid`);
        } else {
            debug(`>>> token is expired`);
            delete storage.token;
        }
    }

    // authenticate if needed
    if (storage.token) {
        // go ahead
    } else if (storage.credentials) {
        const body = jsonToBase64({
            "account_number": storage.credentials.username
        });
//        debug(`>>> body: ${body}`);
        const headers = {"Content-Type": "application/json"};
        const json = getResult("POST", `${baseURL}/auth/v1/token`, headers, body);
        if (json.status != 200) {
            return defaultResponse;
        }
        debug(`>>> CREDENTIALS!!! ${json.response}`);
        const response = JSON.parse(json.response);
        storage.token = {
            accessToken: response.access_token,
            expiryDate: timestampFromISO(response.expiry)
        };
    } else {
        return {
            error: "auth"
        }
    }

    // authenticate with token from now on
    const headers = {
        "Authorization": `Bearer ${storage.token.accessToken}`,
        "Content-Type": "application/json"
    };
    debug(`>>> headers: ${JSON.stringify(headers)}`);

    // get list of devices
    const json = getResult("GET", `${baseURL}/accounts/v1/devices`, headers, "");
    if (json.status != 200) {
        return defaultResponse;
    }
    const devices = JSON.parse(json.response);
    debug(`>>> devices: ${json.response}`);
    debug(`>>> pubkey: ${session.publicKey}`);

    // look up own device
    let myDevice = devices.find(d => session.peer && d.id == session.peer.id);
    if (myDevice) {
        debug(`>>> myDevice: ${JSON.stringify(myDevice)}`);

        // key differs, update remote
        if (myDevice.pubkey != session.publicKey) {
            const body = jsonToBase64({
                "pubkey": session.publicKey
            });
            const json = getResult("PUT", `${baseURL}/accounts/v1/devices/${myDevice.id}/pubkey`, headers, body);
            if (json.status != 200) {
                return defaultResponse;
            }
            myDevice = JSON.parse(json.response);
        }
        // key is up-to-date, refresh local
        else {
            debug(">>> pubkey is up-to-date")
        }
    }
    // register new device
    else {
        debug(`>>> device does not exist`);
        const body = jsonToBase64({
            "pubkey": session.publicKey
        });
        const json = getResult("POST", `${baseURL}/accounts/v1/devices`, headers, body);
        if (json.status != 201) {
            return defaultResponse;
        }
        myDevice = JSON.parse(json.response);
    }

    // update storage
    const peer = {
        id: myDevice.id,
        creationDate: timestampFromISO(myDevice.created),
        addresses: []
    };
    if (myDevice.ipv4_address) {
        peer.addresses.push(myDevice.ipv4_address);
    }
    if (myDevice.ipv6_address) {
        peer.addresses.push(myDevice.ipv6_address);
    }
    session.peer = peer;
    debug(`>>> session: ${JSON.stringify(session)}`);
    storage.sessions[deviceId] = session;
    debug(`>>> storage: ${JSON.stringify(storage)}`);

    const newModule = module;
    newModule.moduleOptions[wgType] = jsonToBase64(storage);
    debug(`>>> module: ${JSON.stringify(module)}`);
    debug(`>>> newModule: ${JSON.stringify(newModule)}`);
    return {
        response: newModule
    };
}
