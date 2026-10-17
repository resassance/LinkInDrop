# LinkInDrop relay

The relay matches two outgoing WebSocket connections and forwards encrypted TLS bytes. Pairing, certificate pinning and per-direction device tokens remain between LinkInDrop devices. The relay does not terminate the inner TLS connection or receive plaintext files and clipboard data. It can observe connection timing, IP addresses and traffic volume.

## Deploy

Use a public server with a domain pointing to it and reachable TCP ports 80 and 443. From this directory:

```sh
RELAY_DOMAIN=relay.example.com docker compose up -d --build
```

Caddy obtains a TLS certificate and forwards WebSockets to the relay. Do not expose the internal HTTP port directly to the internet. Set `wss://relay.example.com` in LinkInDrop under **Настроить доступ без VPN**. The pairing code includes the relay address, so the other device adopts it when it has no relay configured. Both apps must remain running. Direct authenticated LAN/VPN routes are tried alongside the relay.

No service has been deployed automatically. Replace the sample domain with your server's domain before running the command.

## Run without Docker

Node.js 22 or newer:

```sh
npm install
npm test
npm start
```

The default bind address is `127.0.0.1:8080`, suitable behind an HTTPS reverse proxy. Configure `BIND_HOST` and `PORT` as needed. To terminate outer TLS in Node, set `TLS_CERT_FILE` and `TLS_KEY_FILE`. Public clients require `wss://`; unencrypted `ws://` is accepted only for loopback development.

The relay limits message payloads to 1 MiB, disables WebSocket compression, applies connection and pending-tunnel limits and rejects duplicate active room registrations. Room identifiers are random secrets rather than public device IDs. File access still requires the pinned device certificate and authentication token. A forgotten device loses file access even if it remembers an old room identifier. Operators should size bandwidth limits and hosting capacity for their users.

## Verify

`npm test` covers room matching, binary forwarding and rejected registrations. The Flutter relay integration test uses this Node server when its dependencies are installed and verifies pinned TLS pairing and clipboard delivery through it.
