# ZCode Web Remote Control Protocol

This directory documents the wire protocol spoken between a **terminal** (the
web remote-control page in a phone browser, or our Flutter app) and a **device**
(the ZCode desktop app), reconstructed from the desktop app's own code
(`app.asar`, ZCode 3.4.x, extracted 2026-08-16). Vocabulary (device, relay,
terminal, bridge, workspace, session) follows the project's `CONTEXT.md`.

Everything here was re-derived from the asar; earlier reverse-engineering notes
were treated as hypotheses to check, not facts. Where a fact could not be
confirmed in the asar (the terminal side of the relay handshake, WebSocket close
codes), it is marked **[observed]** — verified against the live relay by the
Flutter app's passing E2E runs — rather than **[asar]**.

## The five mechanisms

Messages travel through five stacked mechanisms. Each layer is a separate
document:

| # | Layer | Document | Carries |
|---|-------|----------|---------|
| 1 | Relay WebSocket (JSON control channel) | [01-relay-transport.md](01-relay-transport.md) | pairing, auth, heartbeats, `data` envelopes |
| 2 | App payloads (`zcode_type` JSON inside `data`) | [02-app-payloads.md](02-app-payloads.md) | bootstrap, workspace list, bridge open/close, diagnostics |
| 3 | Acknowledged RPC transport (`rpc-frame` payloads) | [03-acknowledged-rpc-frame.md](03-acknowledged-rpc-frame.md) | fragmented, CRC32-checked, acked byte messages |
| 4 | Binary RPC channel (VS Code-style ChannelClient) | [04-binary-rpc-channel.md](04-binary-rpc-channel.md) | service calls + event subscriptions |
| 5 | Services & V4 data plane (topics, commands, reads) | [05-v4-conversation-data-plane.md](05-v4-conversation-data-plane.md), [06-service-inventory.md](06-service-inventory.md) | conversations, sessions index, workspace config |

```
Terminal (web page / Flutter app)          Device (ZCode desktop)
┌─────────────────────────────┐            ┌────────────────────────────────┐
│ 5  V4 topics / commands     │            │ 5  zcode-agent / zcode-task /  │
│    / service calls          │            │    zcode-session services      │
│ 4  ChannelClient (binary)   │            │ 4  ChannelServer               │
│ 3  AcknowledgedRelayProto   │  rpc-frame │ 3  AcknowledgedRelayProtocol   │
│ 2  app payloads (zcode_type)│ ◄────────► │ 2  payload router              │
│ 1  relay WS (auth/data)     │    data    │ 1  WebRemoteControlDevice      │
└─────────────┬───────────────┘  frames    └───────────┬────────────────────┘
              │        wss://zcode.z.ai/ws?mid=…       │
              └────────────► Relay (z.ai) ◄────────────┘
```

Direction mapping used throughout: **what the device sends is what the terminal
receives**, and vice versa. The asar contains the device side and both shared
schema bundles, so both directions are covered.

## Sources in the asar

| File (under `out/`) | Contains |
|---------------------|----------|
| `main/index.js` | `WebRemoteControlDeviceTransport` (relay client), `createWebRemoteControlManager` (payload router, bridge lifecycle), QR URL builder, auth provider |
| `main/chunk-L5EAZUIY.js` | relay/app-payload/rpc-frame zod schemas, protocol limits, CRC32/base64 wire codecs, endpoint URLs |
| `main/chunk-73KAKK7G.js` | V4 topic/snapshot/row/command zod schemas, `AcknowledgedRelayProtocol`, `RemoteServiceAccess` channel list |
| `main/chunk-LQDBAECE.js` | binary RPC: serialization tags, `ChannelClient`, `MessagePortProtocol`, flow control |
| `host/index.js` | `zcode-agent` service (V4 methods + dynamic events), `zcode-task` adapter facade, `zcode-session` service, `exposeServicesOnMessagePort` |
| `host/chunk-ZJVLE7L2.js` | V4 wire-frame schemas (what dynamic events actually deliver), runtime method ids |

## Hard limits (all layers)

| Limit | Value |
|-------|-------|
| Relay physical frame (`maxPhysicalFrameBytes`) | 1 MiB |
| Logical RPC message (`maxMessageBytes`) | 16 MiB |
| Fragments per RPC message (`maxFragments`) | 64 |
| Fragment assembly timeout | 30 s |
| Replay buffer max | 8 MiB (per bridge) |
| Replay/ack grace | 45 s |
| Saturation high/low watermark | 1 MiB / 256 KiB unacked |
| Heartbeat interval / ack timeout | 10 s / 30 s |
| Rows-range read limit | 200 rows |
| Attachment max / chunk | 20 MiB / 512 KiB, ≤ 64 chunks |
