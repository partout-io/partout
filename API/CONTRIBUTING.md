# Contributing

The latest target is `api/v6`, perform the steps below in that folder.

## New providers

### index.json

The first step is a new entry in [index.json](/api/v6/index.json) following the [Provider][github-provider] format. The metadata is a map of maps, where the key is the module type that the provider supports. At the time of writing, only the `OpenVPN` type is recognized.

Example:

```json
{
    "id": "myprovider",
    "description": "My Provider",
    "metadata": {
        "OpenVPN": {}
    }
}
```

### Script

Next, you need to create a `providers/myprovider.js` script, i.e. named after your provider identifier. Here, you return the servers infrastructure as a [ProviderInfrastructure][github-provider-infrastructure] from a JavaScript function called `getInfrastructure()`, finally encapsulated in a [APIEngine.ScriptResult][github-engine-script-result].

Example:

```javascript
function getInfrastructure() {
    var presets = [];
    var servers = [];

    // build your servers infrastructure here
    // presets represent templates for different module types

    return {
        response: {
            presets: presets,
            servers: servers 
        },
        cache: {
            lastUpdate: "...",  // Last-Modified, if applicable
            tag: "..."          // Etag, if applicable
        }
    }
}
```

where `presets` and `servers` are arrays of [ProviderPreset][github-provider-preset] and [ProviderServer][github-provider-server], respectively.

### Presets

A preset embeds a template defining _how_ to connect to a server. In the case of OpenVPN, for example, it is an OpenVPN configuration where the remotes are injected from the target server. Presets have an ID and require the module type that they are tied to. The module type, in fact, defines the type of the `templateData` field.

The `ProviderPreset.templateData` field is a Base64-encoded JSON whose type depends on `ProviderPreset.moduleType`. If the module type is `OpenVPN`, then the expected template format is [OpenVPNProviderTemplate][github-openvpn-template], where the inner OpenVPN configuration follows the [OpenVPN.Configuration][github-openvpn-configuration] structure.

Example:

```javascript
{
    providerId: "My Provider",
    presetId: "mypreset",
    description: "My Preset",
    moduleType: "OpenVPN",
    templateData: jsonToBase64({
        configuration: {
            "ca": "...PEM here...",
            "cipher": "AES-256-CBC",
            "tlsWrap": openVPNTLSWrap("auth", "...static key here..."),
            ...
            // remotes not required, injected from the server
        },
        endpoints: [
            "UDP:20000", "UDP:30000", "TCP:40000"
            ...
            // endpoints help building the remotes dynamically
        ]
    })
}
```

where `jsonToBase64(json)` and `openVPNTLSWrap(strategy, key)` are API built-ins. [Read below](#built-ins) for a complete list.

### Servers

A server is an entry in the provider infrastructure. Servers must provide a hostname –it can be an IP address– and can specify a set of pre-resolved IPv4 addresses to circumvent issues with DNS resolution. Their location is defined with a country code and an optional area (e.g. a city). Optionally, you can specify a list of IDs of the supported presets, in those cases where not all presets are compatible with the server (default behavior).

Example:

```javascript
const server = {
    serverId: "belgium02",
    hostname: "be-02.myprovider.com",
    ipAddresses: [
        ipV4ToBase64("100.200.1.4"),
        ipV4ToBase64("100.200.1.5")
    ],
    supportedModuleTypes: ["OpenVPN"]
};
const metadata = {
    providerId: "myprovider",
    categoryName: "Default",
    countryCode: "BE"
}

// optional, all presets are supported if this is undefined
server.supportedPresetIds: ["mypreset"];

// optional
metadata.area = "Bruxelles";
metadata.num = 2;

server.metadata = metadata;
```

### Wrap up

You generally have two options:

1. Build the infrastructure statically, like in [TunnelBear](/api/v6/providers/tunnelbear.js)
2. Fetch the response of a provider public API with the `getJSON(url)` API built-in, then convert it to the infrastructure format, like in [Hide.me](api/v6/providers/hideme.js)

Eventually, you will be able to generate your infrastructure JSON with:

```sh
npm run fetch myprovider
```

If this sounds complicated, comparing your output with the one you get from other established providers will help.

### Unit tests

It's highly desirable that you add some basic unit tests in `test/providers`. You may refer to the existing tests, they should be pretty straightforward.

## Built-ins

Below is a list of the additional functions available in the context of a provider script. Base64 is normally used for binary data.

### getText(url)

Returns content from an URL as text.

Example:

```javascript
let result = getText("https://raw.githubusercontent.com/passepartoutvpn/api-cache/refs/heads/master/v6/providers/oeck/fetch.json"
/*
result = {
    response: '{"presets": [], "servers": []}',
    cache: {
        lastUpdate: "...",  // Last-Modified
        tag: "..."          // Etag
    }
};
*/
```

### getJSON(url)

Returns content from an URL as a JSON object.

Example:

```javascript
let result = getText("https://raw.githubusercontent.com/passepartoutvpn/api-cache/refs/heads/master/v6/providers/oeck/fetch.json"
/*
result = {
    response: {
        presets: [],
        servers: []
    },
    cache: {
        lastUpdate: "...",  // Last-Modified
        tag: "..."          // Etag
    }
};
*/
```

### jsonToBase64(object)

Returns a Base64 string from a JSON object. For example, use this for preset template data.

### ipV4ToBase64(ip)

Returns a Base64 string from an IPv4 address. For example, use this for pre-resolved server addresses.

### openVPNTLSWrap(strategy, file)

Returns an object for the `tlsWrap` of an OpenVPN template configuration, given a strategy (`auth` or `crypt`) and the text of the static key without headers.

[github-provider]: https://github.com/passepartoutvpn/partout/blob/master/Sources/API/Provider.swift
[github-provider-infrastructure]: https://github.com/passepartoutvpn/partout/blob/master/Sources/API/ProviderInfrastructure.swift
[github-provider-preset]: https://github.com/passepartoutvpn/partout/blob/master/Sources/Providers/ProviderPreset.swift
[github-provider-server]: https://github.com/passepartoutvpn/partout/blob/master/Sources/Providers/ProviderServer.swift
[github-engine-script-result]: https://github.com/passepartoutvpn/partout/blob/master/Sources/API/APIEngine.swift#L97
[github-openvpn-template]: https://github.com/passepartoutvpn/partout/blob/master/Sources/Partout/Providers/OpenVPN%2BProviders.swift#L45
[github-openvpn-configuration]: https://github.com/passepartoutvpn/partout/blob/master/Sources/OpenVPN/Base/OpenVPN%2BConfiguration.swift#L145
