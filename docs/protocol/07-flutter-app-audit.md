# Layer 7 — Flutter app audit vs the asar-derived protocol

Comparison of the current implementation (`lib/src/relay`, `lib/src/bridge`,
`lib/src/session`) against the documents in this folder, as of 2026-08-16
(app v0.4.x). Each finding cites the layer document it violates.

## Verified correct

- Relay handshake: `auth_init(role:terminal) → auth_challenge → auth_response →
  auth_ack`, proof = `base64url(HMAC-SHA256(passHash, "nonce|role|sid"))` —
  matches [01](01-relay-transport.md) exactly.
- Heartbeat 10 s / 30 s ack timeout, reconnect backoff, `data` envelope shape.
- App payload message set actually used (`workspace-list-*`,
  `workspace-bridge-open/ready/error`, `rpc-frame(-ack)`, `bridge-degraded`,
  `app-error`, `mobile-view-state-update`) — field-complete except where noted.
- Layer-3 frame format (seq/messageSeq/fragmentIndex/fragmentCount/
  messageBytes/checksum/dataBase64), 1 MiB/16 MiB/64-frag/30 s limits.
- Layer-4 message types, serialization tags, wait-for-200 initialization,
  args-array spreading, error-shape copying (`code`/`data`/`detail`/`taskId`/
  `traceId`).
- Command envelope (`sessionId` required-but-nullable key), `createSession`,
  `sendText`, `stop`, `resolveInteraction`, `deleteSession`, `sendGoalCommand`
  payloads; `conversationRowsRangeV4` dual workspace-target shape.
- Service RPC args: `zcode-task` `renameTask`/`archiveTask`/`deleteTask`/
  `getTaskTokenUsage`, `zcode-session` `readSession`/`setModel`/
  `setThoughtLevel`/`readWorkspaceState`.

## Mismatches (must fix in the protocol module)

1. **Topic event payloads are parsed with the wrong shape** — critical
   (fixed, and E2E-verified as *necessary but not sufficient*).
   `parseTopicFrame` switched on `kind ∈ {hello, ack, topic-frame,
   subscriptionState}`, but `onDynamicConversationFrame` /
   `onDynamicSessionsIndexFrame` deliver **wire frames**
   (`{wireVersion:3, kind:"complete"|"fragment", logicalFrameId, …,
   frame|dataBase64}`) — see [05](05-v4-conversation-data-plane.md). Every
   real frame fell into the `_UnknownFrame` branch and was silently dropped.
   Fix: parse wire frames, reassemble `fragment` kind by `logicalFrameId`
   (CRC32), apply the inner topic frame. **E2E verdict (2026-08-16): with
   correct parsing, 204 wire frames still never arrive on terminal
   connections** — all inbound messages are RPC responses, all three dynamic
   event subscriptions register host-side but never fire to the terminal.
   The original "event push does not reach terminals" diagnosis stands; the
   parse fix alone was not sufficient. The wire-frame layer stays in place
   (correct per asar) and the app continues on the polling fallback.

2. **Duplicate layer-3 messages are dropped without re-acking.**
   [03](03-acknowledged-rpc-frame.md): a replayed (already-acked) messageSeq
   must be **re-acked** then dropped. The current code just drops, so after a
   relay reconnect the desktop never sees the ack, exhausts its 45 s replay
   grace, and degrades the bridge (`bridge-degraded → rpc-transport-fault`).

3. **No outbound replay buffer.** After the relay re-pairs, the terminal
   should resend its own unacked layer-3 messages (desktop does exactly this
   via `onSendReady`). Today `acceptAck` is a no-op and nothing is buffered,
   so a `stop`/`resolveInteraction`/`sendText` frame lost in a reconnect is
   gone silently. Fix: keep unacked outbound messages, replay on `paired`.

4. **Inbound rpc-frames are not checked against the bridge identity.**
   Frames from a stale bridge (old `bridgeSessionId`/`bridgeGeneration`) must
   be dropped ([03](03-acknowledged-rpc-frame.md)); the current `acceptFrame`
   accepts any.

5. **`mobile-view-state-update` violates the schema** — `deviceInfo` lacks the
   required `updatedAt` ([02](02-app-payloads.md)); `timezone` is not a schema
   field. Harmless today (device schema is lenient) but should conform.

6. **`unsubscribeConversationV4` args were missing the workspace target** —
   the old call sent `{kind:"unsubscribe", topic, subscriptionId}` with no
   routing fields, so the host could not resolve the subscription and the
   call errored silently (swallowed by `try/catch`), leaking the
   subscription. Fix: send the workspace target. **Verified shape
   (2026-08-16):** the host's `qn`/`nn` route by `workspacePath`
   (`workspaceKey`) + `subscriptionId` — the `topic` field is not read at
   all; `{workspacePath, sessionId, subscriptionId}` (what the module sends)
   is correct. (An earlier draft of this finding suggested a `topic` field;
   that suggestion was wrong — the host resolves the topic from its own
   registry.)

7. **Negative int32 decode** — the desktop writes int32 negatives as unsigned
   varints (JS `value & 0xFFFFFFFF`); JS readers sign-extend via int32
   coercion, our `readVarint` does not. Any negative int field decodes as a
   large positive number. Fix: sign-extend in the tag-6 decode path.

8. **Docs/comments wrong about the proof order** — ADR-0001 says the message
   is `"$sid|$nonce|terminal"`; the asar uses `"nonce|role|sid"` for both
   roles. `relay_client.dart`'s comment also claims the device role uses a
   different order — false. Code is right; docs must be fixed.

9. **CRC/length mismatches drop silently** — the desktop treats them as fatal
   bridge faults ([03](03-acknowledged-rpc-frame.md)); the app should at least
   surface/escalate instead of continuing with a corrupted stream.

## Gaps (protocol surface the app does not use yet)

From [02](02-app-payloads.md): `bootstrap-request` (restores last-viewed
workspace/task via `initialViewState`/`mobileViewState`),
`workspace-reconnect-request` (remote workspaces), `platform-request`,
`mobile-diagnostic` reporting.

From [05](05-v4-conversation-data-plane.md): `workspace-config` topic
(config options + slash commands); attachments (upload/download);
`conversationPlansV4`, `conversationFileChangesV4`,
`conversationFileRewindPreviewV4`; queue commands (`sendQueuedNow`,
`editQueueItem`, `reorderQueueItem`, `deleteQueueItem`, `setAutoDrain`);
`compact`, `forkAssistant`, `editUserQuery`, `retryTurn`,
`setAssistantFeedback`, `snoozeInteractionAutoResolution`, `pauseGoal`,
`resumeGoal`, `cancelBackgroundWork`, `switchCollaborationMode`,
`setFollowupMode`; `queryConversationCommandsV4` (idempotent retry support);
saturation flow control.

From [06](06-service-inventory.md): `onDynamicTaskTerminalOutcome` /
`onDynamicTaskReady` (would drive push notifications without polling),
`onDynamicWorkspaceEvent`, `broadcast` channel, task snapshot APIs
(`getTaskSnapshot*`), `listArchivedTasks` (archive browsing), subagent
progress (`subagents` snapshot field).

Deliberate non-goals for v1 (unchanged): plugin/automation management,
usage stats, OAuth, bots, repo-wiki — desktop-management surface the phone
does not need.

## Interaction resolution audit (2026-08-16, ask from the user)

Audit of the clarification-question (AskUserQuestion) and permission-request
(approval) implementations against the asar, following the E2E run.

### Verified correct

1. **Data source.** The app polls `zcode-session.readSession` and reads
   `projection.pendingPermissions`. The runtime's authoritative schema
   (`Ao` in `out/host/chunk-XRHTBW6U.js`) is `Jx = {requestId, toolCallId,
   toolName, reason, riskLevel, input?: unknown, origin?, options: [ $u ],
   requestedAt}` with `$u = {optionId, kind, name, description?, response}`.
   `PendingRequest` / `PendingRequestOption` parse exactly these fields.
   AskUserQuestion entries carry `input.questions`; permission entries carry
   `options` (this single array serves both kinds — the host's
   `pendingPermissions`/`pendingElicitations` split in `_l` applies only to
   the zcode-task snapshot builder, not to the session read the app uses).
2. **requestId ↔ interactionId identity.** The renderer's own mapping
   (`cSt`, `styles-OqUHW1P0.js`) sets `requestId: t.interactionId` when
   building permission requests from snapshot interactions, and resolves with
   `{interactionId, answer}` — exactly what the app sends.
3. **Answer shapes.** The renderer's AskUserQuestion answer builder (`_xt`)
   produces `{answers: {question: "v1, v2"}, answer_<i>: …, answer: …}` —
   byte-identical semantics to the app's `buildQuestionAnswerContent`.
   `action: "accept"|"cancel"` matches the runtime's `respond_elicitation`
   enum; permission resolution via `optionId` matches `respond_permission`
   (the runtime looks the option's `response` up itself).
4. **E2E evidence.** The AskUserQuestion flow (multi-question, multi-select,
   custom answers) was verified live in v0.4.1.

### Bug: approvals have no working UI

The `_RequestSheet` builds its pages **only from `request.questions`**; a
permission request has none, so an approval-only sheet renders an empty
`PageView` and the bottom button row evaluates `_pages[_page]` on an empty
list (`conversation_page.dart` `_currentAnswered`) → `RangeError` during
build. There is no allow/deny/custom button anywhere in the UI (grep for
`allowOnce`/`deny` finds none). v0.4.0's "approval sheet is isomorphic to the
verified question sheet" assumption was wrong. The readSession Jx entries
carry no kind discriminator, so distinguishing kinds relies on the
questions/toolName heuristic, which also misroutes `freeText`-only userInput
interactions (no questions → treated as permission → same crash). Secondary
gaps: `sensitive` masking and `autoResolution` countdowns are ignored
(benign — the runtime auto-resolves after its deadline).

## Remediation

All of the above feed the `lib/src/protocol/` module refactor: mismatches
1–9 are fixed there; gaps are left as typed-but-unused API surface so adding
features later touches only the protocol module's public exports.

## Second-pass fixes (2026-08-16, post-review)

Follow-up review of the v0.5 module surfaced and fixed:

- **deliveryKind now threads through.** `WireFrameAssembler` returns the
  envelope metadata (`deliveryKind`, `wireVersion`, `logicalFrameOrdinal`)
  alongside the inner frame; `TopicFrame` carries `deliveryKind`, so the
  `online` stale-replay guard in `conversation_controller` is live again.
  Unknown `wireVersion` values are dropped with a log.
- **Replay grace implemented.** Unacked outbound older than
  `ProtocolLimits.replayGraceMs` (45 s) degrades the transport
  (`remote.rpcFrame.replayGraceExceeded`), mirroring the desktop deadline.
- **Inbound geometry limits.** `fragmentCount ≤ 64` and index range are
  enforced before assembly; violations degrade (`invalidPayload`).
- **Assembly timeout is a fault.** The shared `FragmentAssembler`'s stale
  sweep degrades the transport (`remote.rpcFrame.assemblyTimeout`) instead
  of silently dropping — symmetric with the desktop.
- **Notification feed restored.** `pollLatest` again inlines
  `control`/`meta`/`pendingInteractions` from rowsRange responses — with
  event push still absent (E2E), those inlined fields are the only source
  for the pending-interaction notification hook.
- **Shared fragment assembly.** `lib/src/protocol/core/fragment_assembler.dart`
  now backs both the rpc-frame transport and the topic wire-frame assembler
  (mechanical assembly only; validation/fault policy stays per layer).
- **Workspace key unification.** `Workspace.fromJson` and the
  workspace-list merge both derive the key as `workspaceIdentity || path`
  (docs/protocol/02); the merge lives on `WorkspaceListData.mergedEntries`,
  fixing duplicate entries for remote (identity-carrying) workspaces.
- **Oversize send no longer poisons the bridge.** `sendMessage` throws a
  typed `RpcTransportException` for empty/oversized messages instead of
  degrading the whole transport (empty messages were invalid per the schema
  anyway: `messageBytes ≥ 1`, base64 ≥ 4 chars).
- **Service wrappers share a base class** (`WorkspaceService`); the stale
  `_sessionChannel` field was renamed to `_topicSession`; `mobile-diagnostic`
  gained its typed builder.

## E2E verification results (2026-08-16, real device)

Verified on-device (release build, `ZREMOTE_LOG=true`): relay auth
handshake + heartbeat; workspace list; bridge open (with `taskId`);
acknowledged transport assembly, per-message acks and unacked-byte tracking;
channel init (type 200), all three dynamic-event subscriptions register
host-side (`[rpc:listen] … subscribed`); `helloConversationV4`,
`initializeConversationV4` (clientHello), `subscribeConversationV4`,
`resyncConversationV4`, `conversationRowsRangeV4`, `zcode-session.readSession`
(2 s cadence), `zcode-task.getTaskTokenUsage` (6 s); `sendConversationCommandV4`
(sendText) accepted by the runtime; `mobile-view-state-update` no longer
dropped by the device (finding 5 fix confirmed — zero `invalid external relay
payload dropped` after v0.5, previously every session). Not delivered:
204 wire-frame events (see finding 1 verdict). Not tested on device: `stop`
command (same command envelope as sendText, proven; pressing it would have
interrupted the live session under test) and relay-reconnect replay (test
aborted when airplane mode cut the Wi-Fi adb link; the replay machinery is
covered by unit tests).
