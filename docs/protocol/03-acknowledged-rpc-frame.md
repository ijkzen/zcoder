# Layer 3 — Acknowledged RPC frame transport (`rpc-frame`)

Carries arbitrary byte messages (layer 4 bodies) between terminal and device
*reliably* over the lossy relay link: fragmentation, CRC32 verification,
message-level acks, replay-after-reconnect, and flow control.

Source: `AcknowledgedRelayProtocol` in `out/main/chunk-73KAKK7G.js`, frame
schemas + CRC/base64 codecs in `out/main/chunk-L5EAZUIY.js` [asar].

## Frame formats

`rpc-frame` (one physical fragment of one logical message):

```
{ zcode_type: "rpc-frame",
  bridgeSessionId,                    // identity of the bridge
  bridgeGeneration?, recoveryId?,     // echo of workspace-bridge-open
  seq:            int > 0,            // physical frame counter, per direction, starts at 1
  messageSeq:     int > 0,            // logical message counter, per direction, starts at 1
  fragmentIndex:  int >= 0,           // < fragmentCount <= 64
  fragmentCount:  int >= 1,
  messageBytes:   int >= 1,           // total logical message size, <= 16 MiB
  checksum: { algorithm: "crc32", value: "<8 lowercase hex>" },  // CRC32 of the WHOLE message
  dataBase64:     canonical base64 }  // fragment bytes; min 4 chars, total frame <= 1 MiB
```

`rpc-frame-ack`:

```
{ zcode_type: "rpc-frame-ack", bridgeSessionId, bridgeGeneration?, recoveryId?,
  ackMessageSeq: int > 0 }            // cumulative: "everything <= this is received"
```

CRC32 is the standard reflected polynomial (0xEDB88320), output as 8 lowercase
hex chars; base64 is canonical (re-encoding the decoded bytes reproduces the
string exactly).

## Sending (per side)

1. Assign `messageSeq = ++counter`, split the message into ≤ 64 fragments each
   ≤ 1 MiB on the wire, compute the whole-message CRC32.
2. Frames go out in order; `seq` increments per physical frame.
3. Keep the message in a **replay buffer** until the peer acks it (max 8 MiB
   total, 45 s grace — exceeding either is a fatal fault).
4. On reconnect (`matched` again), **replay all unacked messages** from
   fragment 0 before sending anything new.

## Receiving

1. Drop frames whose `bridgeSessionId`/`bridgeGeneration`/`recoveryId` do not
   match the current bridge (stale traffic from a previous bridge).
2. Assemble fragments by `messageSeq`; assembly older than 30 s is discarded
   (fault).
3. On completion: verify length (`messageBytes`) and CRC32; deliver the bytes
   upward; send `rpc-frame-ack` with that `messageSeq`.
4. **Duplicates must be re-acked** (the peer resent because it missed the ack),
   then dropped.
5. Ack what you received even while you still have outbound data queued.
   Acks are cumulative (`<= ackMessageSeq` releases the replay buffer); the
   desktop coalesces them into its outbound flush (one pending ack, highest
   `messageSeq` wins), but sending an ack immediately per completed message
   is equally valid — the peer treats both identically.

## Flow control & faults

- Track unacked outbound bytes. Crossing **1 MiB** → `saturated`; draining back
  under **256 KiB** → `drained`. (On the device these propagate to the host as
  `connection-flow-v1` events; a terminal may simply stop/resume sending large
  reads.)
- Fatal faults (bridge is dead, both sides are told via `bridge-degraded` /
  the device marks the bridge degraded and stops routing):
  `remote.rpcFrame.envelopeTooLarge | encodingFailed | outerMeterFailed |
  replayBufferExceeded | replayGraceExceeded | ackGraceExceeded |
  sendFailed | invalidPayload | futureAck | frameGap | assemblyTimeout |
  deliveryFailed`. Notably `futureAck` guards against acking a messageSeq the
  peer never fully sent, and `frameGap`/`assemblyTimeout` fire on incomplete
  or stale assemblies.
- Sequence rules: an ack for a `messageSeq` higher than the highest fully-sent
  message is a protocol violation → degrade. Acks are cumulative — releasing
  buffer entries `<= ackMessageSeq`.
