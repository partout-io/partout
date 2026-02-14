# ``PartoutOpenVPN``

A Swift/C implementation of the OpenVPN® protocol.

## Overview

This is a simplified Swift/C implementation of the [OpenVPN®][dep-openvpn] protocol.

The client is known to work with OpenVPN® 2.3+ servers.

- [x] Handshake and tunneling over UDP or TCP
- [x] Ciphers
    - AES-CBC (128/192/256 bit)
    - AES-GCM (128/192/256 bit, 2.4)
- [x] HMAC digests
    - SHA-1
    - SHA-2 (224/256/384/512 bit)
- [x] NCP (Negotiable Crypto Parameters, 2.4)
    - Server-side
- [x] TLS handshake
    - Server validation (CA, EKU)
    - Client certificate
- [x] TLS wrapping
    - Authentication (`--tls-auth`)
    - Encryption (`--tls-crypt`)
- [x] Compression framing
    - Via `--comp-lzo` (deprecated in 2.4)
    - Via `--compress`
- [x] Key renegotiation
- [x] Replay protection (hardcoded window)

The library therefore supports compression framing, just not compression. Remember to match server-side compression framing, otherwise the client will shut down with an error. E.g. if server has `comp-lzo no`, client must use `compressionFraming = .compLZO`.

### Support for .ovpn files

Most options seen in .ovpn configuration files can be parsed with ``StandardOpenVPNParser``.

### Tunnelblick XOR patch

Partout fully supports the non-standard [Tunnelblick XOR patch][dep-tunnelblick-xor]:

- Multi-byte XOR Masking
    - Via `--scramble xormask <passphrase>`
    - XOR all incoming and outgoing bytes by the passphrase given
- XOR Position Masking
    - Via `--scramble xorptrpos`
    - XOR all bytes by their position in the array
- Packet Reverse Scramble
    - Via `--scramble reverse`
    - Keeps the first byte and reverses the rest of the array
- XOR Scramble Obfuscate
    - Via `--scramble obfuscate <passphrase>`
    - Performs a combination of the three above (specifically `xormask <passphrase>` -> `xorptrpos` -> `reverse` -> `xorptrpos` for reading, and the opposite for writing)

See ``OpenVPN/ObfuscationMethod`` for more details.

## Topics

### Module

- ``OpenVPN``
- ``OpenVPN/Configuration``
- ``OpenVPNConfiguration``
- ``OpenVPNModule``

### Parser

- ``KeyDecrypter``
- ``StandardOpenVPNParser``
- ``StandardOpenVPNParserError``

[dep-openvpn]: https://openvpn.net/index.php/open-source/overview.html
[dep-tunnelblick-xor]: https://tunnelblick.net/cOpenvpn_xorpatch.html
