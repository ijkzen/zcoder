# Layer 2 — Application payloads (`zcode_type`)

Inside each relay `data` frame, `payload` is a JSON object discriminated by
`zcode_type`. Source: payload router `routePayload` + schema union in
`out/main/index.js` and `out/main/chunk-L5EAZUIY.js` [asar].

Conventions:

- Requests carry a terminal-generated `requestId` (string). The device replies
  with a message of the corresponding `*-response`/`*-ready`/`*-error` type
  echoing that `requestId`. There is no timeout on the device side — the
  terminal owns timeouts.
- All these payloads only flow once the relay link is `matched`.
- `bridgeSessionId` / `bridgeGeneration` / `recoveryId` identify one bridge
  (layer 3 session); `[A-Za-z0-9._~-]{1,256}`.

## QR / connect URL [asar]

`buildWebRemoteControlExternalQrUrl`:

```
https://zcode.z.ai/remote/v4?sid=<deviceSid>&hash=<passHash>&t=<millis>
    &mid=<deviceMid>&name=<deviceName>&app_version=<version>
```

(`mid`/`name`/`app_version` omitted when empty. `/remote/v3` for app versions
below the v4 cutoff.) This URL is both what the QR encodes and what a browser
opens; our Flutter app parses `sid`/`hash` out of it as the pairing credential.

## Terminal → device

| `zcode_type` | Fields | Device does | Terminal receives |
|---|---|---|---|
| `bootstrap-request` | `requestId` | replies with full bootstrap (below) | `bootstrap-response` |
| `workspace-list-request` | `requestId` | replies with workspaces + tasks | `workspace-list-response` |
| `platform-request` | `requestId`, `method`, `args?` | runs a desktop platform helper | `platform-response` (`success:true`+`result` or `success:false`+`error`) |
| `workspace-bridge-open` | `requestId`, `bridgeSessionId`, `bridgeGeneration?`, `recoveryId?`, `workspaceKey`, `taskId?` | attaches the workspace host process and wires layer 3/4 | `workspace-bridge-ready` or `workspace-bridge-error` |
| `workspace-reconnect-request` | `requestId`, `workspaceKey` | re-dials a disconnected (remote) workspace | `workspace-reconnect-response` (`success:true` or `+error`) |
| `mobile-view-state-update` | `viewState {activeWorkspaceKey?, activeTaskId?, updatedAt}`, `deviceInfo?` | remembers which workspace/task the phone is viewing (used for `initialViewState` on next bootstrap) | nothing (fire-and-forget) |
| `rpc-frame` / `rpc-frame-ack` | see [03](03-acknowledged-rpc-frame.md) | feeds layer 3 | (acks/data via layer 3) |
| `mobile-diagnostic` | see below | logs only | nothing |

`platform-request.method` ∈ `isDockerAvailable`, `listWSLDistros`,
`listDockerContainers`, `listSSHConfigAliases`, `loadMcpFromUserDirectory`,
`saveMcpToUserDirectory`, `migrateLegacyCommonMcp`.

`mobile-diagnostic` fields (device logs them for support):
`event` ∈ `state-transition|socket-close|socket-error|recover-start|
recover-scheduled|pair-status|failure`, `timestamp` (int), plus optional
`state`, `previousState`, `pairStatus`, `closeCode`, `closeReason`, `wasClean`,
`wasPaired`, `failureReason`, `failureMessage`, `visibilityState`, `online`,
`hiddenDurationMs`.

## Device → terminal

| `zcode_type` | Fields | Terminal should |
|---|---|---|
| `bootstrap-response` | `requestId`, `success:true`, `result {windowControlSessionId, workspaces, tasks, initialViewState?, mobileViewState?}` | seed workspace/task lists, restore last view |
| `workspace-list-response` | `requestId`, `success:true`, `result {workspaces, tasks?, activeWorkspaceKey?, activeTaskId?}` | replace workspace/task lists |
| `workspace-list-updated` | `result` (same shape) | push notification that lists changed (device dedupes identical content by signature before sending) |
| `workspace-bridge-ready` | `requestId`, `bridgeSessionId`, `bridgeGeneration?`, `recoveryId?`, `bridge` (identity echo: `{bridgeSessionId, bridgeGeneration?, recoveryId?, kind: local\|remote, workspaceKey, workspacePath, [workspaceIdentity, remoteSessionId], initialTaskId?}`) | start layer 3/4 traffic with that bridge identity; flush pending layer-3 frames |
| `workspace-bridge-error` | `requestId`, `bridgeSessionId?`, …, `reason`, `error` | show failure; `reason` maps device error codes (see below). Also pushed unsolicited with `requestId: "remote-session-closed:<id>"` when a remote workspace dies |
| `workspace-reconnect-response` | `requestId`, `workspaceKey`, `success`, `error?` | refresh workspace list on success |
| `platform-response` | `requestId`, `method`, `success`, `result?`/`error` | resolve the pending platform call |
| `bridge-degraded` | `bridgeSessionId`, `bridgeGeneration?`, `recoveryId?`, `reason` ∈ `rpc-transport-fault|rpc-frame-gap|buffer-overflow|buffer-timeout`, `seq?`, `expectedSeq?`, `droppedCount?` | the bridge's layer 3 is dead — reopen the bridge (new `bridgeSessionId`) or tell the user to reconnect |
| `app-error` | `requestId?`, `bridgeSessionId?`, `reason`, `error` | fatal session error; the device tears the runtime down. `reason` see below |
| `rpc-frame` / `rpc-frame-ack` | layer 3 | feed layer 3 |

`app-error`/bridge `reason` enum:
`session-not-found | session-expired | session-conflict | workspace-closed |
desktop-disconnected | invalid-mobile-connection | desktop-bootstrap-timeout |
connection-recovery-timeout | relay-unavailable | unsupported-action |
unexpected-error` (device error-code mapping: `DESKTOP_HOST_MISSING` →
`desktop-disconnected`; `REMOTE_SESSION_MISSING`/`REMOTE_SESSION_WINDOW_MISMATCH`
→ `workspace-closed`; `REMOTE_WORKSPACE_IDENTITY_*` → `unsupported-action`).

## Shared shapes

Workspace entry (`workspaces[]`):

```
{ workspacePath, workspaceIdentity?, remoteSessionId?, label,
  workspacePurpose?: "project"|"conversation", kind: "local"|"remote",
  connectionState?: "connected"|"disconnected"|"reconnecting", lastConnectionError? }
```

Task entry (`tasks[]`):

```
{ taskId, title, workspacePath, workspaceIdentity?, remoteSessionId?,
  workspaceLabel, workspaceKind: "local"|"remote", createdAt, updatedAt,
  provider?, unreadAt?, displayStatus?: "idle"|"running"|"completed"|"error",
  pinned?, archived? }
```

`workspaceKey` = `workspaceIdentity` if present, else `workspacePath`.

Device behavior worth knowing: the device keeps a 50-slot outbound payload
buffer while the relay link is down and flushes it on `matched`; payloads older
than 5 s in the buffer are dropped with a log line. `workspace-list-updated` is
content-deduped per window.
