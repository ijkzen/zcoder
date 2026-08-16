# Layer 4 — Binary RPC channel (ChannelClient/ChannelServer)

A VS Code-style RPC protocol: named channels, promise calls, and event
subscriptions, carried as typed-serialized values. Over the web-remote path the
bodies travel inside layer-3 messages **without** any additional socket header
(the 13-byte header below belongs to the device-internal `SocketProtocol` over
stdio/TCP and is not used on the relay path) — the terminal sends and receives
the serialized values directly.

Source: `out/main/chunk-LQDBAECE.js` [asar].

## Initialization

The **server sends the first frame**, type `200` (initialize), as soon as the
bridge's layer-3 link is up. A client must not send anything before receiving
it (the device discards early requests).

## Message types

Client → server: serialized `[msgType, requestId, channel, method]` followed by
a second serialized value, the args.

| Type | Name | Body | Server does |
|------|------|------|-------------|
| 100 | request | `[100, id, channel, method]` + args | invokes `channel.method(...args)`; replies 201/202/203 |
| 101 | cancel | `[101, id]` + undefined | cancels the pending call (reply 203) |
| 102 | listen | `[102, id, channel, event]` + args | subscribes; each firing arrives as 204 |
| 103 | dispose | `[103, id]` + undefined | unsubscribes |

Server → client:

| Type | Name | Body | Client does |
|------|------|------|-------------|
| 200 | initialize | (none) | mark ready; flush queued requests |
| 201 | reply success | `[201, id]` + result | resolve promise |
| 202 | reply error | `[202, id]` + error object | reject: `{name, message, stack?, code?, data?, detail?, details?, taskId?, traceId?}` — `code`/`data`/`detail`/`details`/`taskId`/`traceId` are copied onto the Error |
| 203 | reply cancel/error-data | `[203, id]` + value | reject with the raw value |
| 204 | event fire | `[204, id]` + event data | dispatch to the subscription |

`id` is a per-connection request counter starting at 0. Events: a plain event
(`onXxx`) takes no args; a **dynamic event** (`onDynamicXxx(arg)`) takes one
argument (e.g. the workspace/session target) and returns a subscription tied to
that argument — unsubscribing is dispose (103).

## Value serialization

One-byte type tag, then payloads with 7-bit LEB128 varint lengths:

| Tag | Type | Encoding |
|-----|------|----------|
| 0 | undefined | nothing |
| 1 | string | varint byteLength + UTF-8 bytes |
| 2 | Buffer (Uint8Array) | varint length + raw bytes |
| 3 | VSBuffer | same as 2 |
| 4 | array | varint count + serialized items |
| 5 | object | varint length + JSON text; on decode, revive `{__zcode_rpc_nested_uint8array_v1:true, base64:"…"}` back to bytes |
| 6 | int32 | varint of the **unsigned** two's-complement bits |

Anything not covered (bool, double, >32-bit int, maps) is JSON-encoded as tag 5.
Negative int32: JS writes `value & 0xFFFFFFFF` — the reader must sign-extend
when the high bit is set.

## Flow control

`{__zcodeRpcControl:"connection-flow-v1", state:"saturated"|"drained"|"closed"}`
— used device-internally on message ports; on the relay path backpressure is
layer 3's job (watermarks), so a terminal does not need to emit these.
