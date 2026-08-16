# Layer 1 — Relay WebSocket transport

The relay (`wss://zcode.z.ai/ws`) is the z.ai-hosted WebSocket service that
matches a device with its terminals and forwards frames between them. Both ends
connect out to it; there is no direct phone↔desktop socket.

Source: `WebRemoteControlDeviceTransport` in `out/main/index.js` [asar];
terminal-side behavior verified by the Flutter app's E2E [observed].

## Connection

- URL: `wss://zcode.z.ai/ws?mid=<deviceMid>` (query param `mid`), plus header
  `X-Device-ID: <deviceMid>`. The terminal uses the `mid` from the QR URL
  (empty string if absent) [observed].
- `permessage-deflate` is negotiated by the device; harmless if a terminal does
  not.
- Every frame is **JSON text** with a `type` field. A frame larger than
  **1 MiB** is dropped by the device (`maxPhysicalFrameBytes`); the relay is
  expected to enforce the same.

## Auth handshake

Credentials come from the QR URL (see [02-app-payloads.md](02-app-payloads.md)):
`sid` = device session id, `hash` = `base64(sha256(password))` (`passHash`).

Proof function (identical for both roles) [asar]:

```
proof = base64url(HMAC-SHA256(key = passHash, message = f"{nonce}|{role}|{sid}"))
```

The device calls it with `(nonce, "device", deviceSid)`. The terminal calls it
with `(nonce, "terminal", sid)`. Both use the order `nonce|role|sid`.

```
terminal/device                relay
──────────────────────────────────────────────────────────────
auth_init      ────────────►
               ◄──────────── auth_challenge {nonce}
auth_response  ────────────►
               ◄──────────── auth_ack {pair_status}
   … heartbeats + data frames …
```

### Messages

All timestamps are epoch milliseconds. `meta` is
`{platform, version, name}` (device sends `process.platform`, app version,
device name; the terminal sends its own platform/client name) [observed].

| Message | Direction | Fields | Receiver should |
|---------|-----------|--------|-----------------|
| `auth_init` | client→relay | `role` ("terminal"/"device"), `device_sid`, `meta`, `client_ts` | relay binds the credential to the socket |
| `auth_challenge` | relay→client | `nonce` | compute proof, reply `auth_response` |
| `auth_response` | client→relay | `device_sid`, `proof`, `client_ts` | relay verifies possession of `passHash` |
| `auth_ack` | relay→client | `pair_status` | enter paired/waiting state (first status after auth) |
| `pair_status_query` | client→relay | `device_sid`, `client_ts` | heartbeat; relay answers `pair_status_ack` |
| `pair_status_ack` | relay→client | `pair_status` | refresh "last ack" clock; apply pair status |
| `data` | both | `payload` (any JSON), `client_ts`, `server_ts?` | hand `payload` to layer 2 |
| `error` | relay→client | `code`, `message` | see error handling below |
| `device_register_init` | device→relay | `device_mid`, `pass_hash`, `meta`, `client_ts` | first-ever registration (device only; terminal never sends) |
| `device_register_ack` | relay→device | `device_sid` | device persists `{deviceSid, passHash}` and continues with `auth_init` |

`pair_status` ∈ `"waiting"` (other end offline) | `"matched"` (both ends
online). On `matched` the relay starts forwarding `data` frames between the
matched pair.

## Heartbeat & liveness

- Every 10 s send `pair_status_query`; every `pair_status_ack` (or any
  auth/pair ack) refreshes `lastPairStatusAckAt`.
- If no ack for **30 s** → the link is stale → close and reconnect
  [asar].
- Device-side extra: if a previously-paired device sees `waiting` twice in a
  row (terminal vanished and relay notices first) it force-reconnects after a
  15 s grace. A terminal can simply rely on the 30 s ack timeout.

## Error codes (`error.code`) [asar]

| Code | Meaning | Terminal action |
|------|---------|-----------------|
| `KICKED` | another terminal took over the pairing | surface "session conflict"; do not auto-reconnect into a loop |
| `AUTH_FAILED` | bad proof / revoked credential | drop the pairing; re-scan QR. (Device side additionally falls back to re-register once.) |
| `INTERNAL` | relay internal error | reconnect with backoff |
| `WRONG_PARAM` | malformed frame (e.g. re-sending `auth_init` while waiting) | reconnect and restart the handshake cleanly |
| `DEVICE_OFFLINE` | [observed] device not connected while terminal authenticates | keep waiting; relay will send `pair_status_ack` when device returns |

## WebSocket close codes [observed]

| Code | Meaning |
|------|---------|
| 4004 | session not found (bad `sid`) |
| 4009 | session conflict (second terminal) |
| 4010 | device disconnected |
| 4011 | pairing expired — re-scan |
| 4012 | workspace closed |
| 4013 | invalid mobile connection |

## Terminal state machine [observed]

`connecting → authenticating → paired ⇄ waiting (device offline) → closed`,
with reconnect backoff (500 ms doubling, cap 10 s). While `waiting`, do **not**
re-send `auth_init` — the relay answers `WRONG_PARAM`; hold the socket and wait
for `pair_status_ack: matched`. If nothing matches within ~60 s, rebuild the
connection from scratch.
