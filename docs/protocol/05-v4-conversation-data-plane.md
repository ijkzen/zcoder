# Layer 5a — V4 conversation data plane (topics, commands, reads)

The application-level protocol over the `zcode-agent` channel: topic
subscriptions (conversation, sessions index, workspace config), conversation
commands, history/usage reads, and attachment transfer.

Sources: schemas in `out/main/chunk-73KAKK7G.js` + `out/host/chunk-ZJVLE7L2.js`,
service methods in `out/host/index.js` (`*V4`) [asar].

## Topics

Three topic kinds, addressed as strings:

| Topic | Length suffix | Carries |
|-------|---------------|---------|
| `conversation/<sessionId>` | 13 chars | full session state + conversation rows |
| `sessions-index/<workspaceKey>` | 15 chars | the workspace's session list |
| `workspace-config/<workspaceKey>` | 17 chars | config options + slash commands |

## Wire frames (what `onDynamic*Frame` events deliver)

**Important:** the dynamic events do **not** deliver bare topic frames. They
deliver a *wire frame* envelope (`wireVersion: 3`) [asar, verified against the
event fire site in `out/host/index.js`]:

```
{ wireVersion: 3,
  kind: "complete" | "fragment",
  deliveryKind: "initial" | "online" | "recovery",
  logicalFrameId: string,          // groups fragments of one logical frame
  logicalFrameOrdinal: int > 0,
  topic, subscriptionId,

  // kind = "complete":
  frame: { topic, subscriptionId, fromSeq, toSeq, sentAt,
           payload: {kind:"snapshot", snapshot} | {kind:"deltas", deltas:[…]} },

  // kind = "fragment":
  fragmentIndex, fragmentCount, logicalBytes,
  checksum: {algorithm:"crc32", value:"<8 hex>"},
  dataBase64 }                     // reassemble fragments → JSON of `frame`
```

`deliveryKind`: `initial` = first snapshot after subscribe; `online` = live
push; `recovery` = replay after a gap. A consumer applies `complete` frames
directly, reassembles `fragment` frames by `logicalFrameId` (CRC32-checked,
≤ 64 fragments), then applies the inner frame.

Apply rules for the inner frame: snapshot replaces all state and sets
`(logEpoch, seq = toSeq)`; deltas apply only when `fromSeq == current seq`
(a gap ⇒ resync — send `resync*V4` with `base:{logEpoch, seq}` or
`forceSnapshot:true`); `toSeq <= current` duplicates are no-ops.

## Conversation snapshot (`conversation/…` payload.snapshot)

```
{ protocolVersion: 1, sessionId, logEpoch, seq, revision,
  control:      { phase: "draft"|"prewarming"|"running"|"completedSuccess"|
                          "completedInterrupted"|"error",
                  sessionEnded, canStop,
                  stopState: "idle"|"stoppable"|"stopping", stopTargetKind,
                  activeWorks: [{kind, foregroundExecutionId?, startedAt}],
                  lastError: {code, message, recoverable, at, source, …}|null,
                  apiRetry: {attempt, maxAttempts, nextRetryAt, reasonCode}|null },
  availability: {fork, compact, switchModelConfig, setFollowupMode, queueEdit,
                 sendQueuedNow, pauseGoal, resumeGoal}  // {allowed, reasonCode?}
  inputRouting: {mode: "startNow"|"enqueue"|"guide"|"reject"|"choice", reasonCode?},
  meta:         {title, titleSource: "default"|"generated"|"custom"},
  config:       {provider, model, thought, thoughtLevels[], followupMode, mode},
  modelTransition: {eventId, origin, from{provider,model}, to{provider,model}}|null,
  usage:        { contextWindow: {usedTokens, maxTokens, autoCompactThresholdTokens,
                                  cache?, breakdown?}|null,
                  cumulative: {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens} },
  queue:        {items: [queued input…], autoDrain, pauseReason?},
  pendingInteractions: [interaction…],   // see below
  pendingCommands: [{commandId, clientId, type, state: "accepted"|"executing", at}],
  backgroundWorks: [{workId, kind: "bash"|"subagent", title,
                     status: "running"|"resultPending"|"failed"|"cancelled",
                     startedAt, endedAt?, cancellable?, blocked?, anchorRowId,
                     childSessionId?}],
  subagents?:   {revision, childSessionIds, running:[{childSessionId, agentId?,
                     subagentType, title, summary?, status, startedAt?}], endedTotal},
  goal?:        {targetId, objective, summaryTitle, status: "active"|"paused"|"verifying"|
                     "verified"|"notSatisfied"|"failed", iteration,
                     verifications[], iterations[]},
  plan?:        {items: [{id, content, status: "pending"|"inProgress"|"completed"}], updatedAt},
  rows:         {window: [row…], totalCount, firstRowId} }
```

Pending interaction (approval / question card):

```
{ interactionId, kind: "permission" | "userInput", anchorRowId, createdAt,
  autoResolution?: {state:"hiddenGrace"|"visibleCountdown", startedAt, visibleAt, deadlineAt}
                 | {state:"snoozed", startedAt, snoozedAt},
  payload:
    permission: {toolCallId, toolName, summary, detail,
                 options: [{optionId, label, kind: "allowOnce"|"allowAlways"|"deny"|"custom"}]}
  userInput:  {prompt, freeText, options?:[{optionId,label}], sensitive?, toolName?,
               toolCallId?, traceId?, questions?:[{question, header,
                 options:[{value,label,description?,preview?}], multiSelect?}],
               currentQuestionIndex?, answerDrafts?} }
```

### Conversation rows

Base row: `{rowId, turnId, entityId?, productTurnId?, visibility?, createdAt,
createdAtSeq, actions?: {canFork, canEdit, canRetry, canRewindFiles,
editDisposition}}`. Kinds (`kind` field):

| kind | Extra fields |
|------|--------------|
| `turnHeader` | `origin` (userInput/backgroundResult/goalContinuation/editRerun), `state` (running/completedSuccess/completedInterrupted/failed), `startedAt`, `endedAt?`, `activeMs?`, `workSegments?`, `originMeta?`, `fileChanges?: {additions, deletions, files, state}` |
| `userInput` | `text`, `origin` (realUser/backgroundResult/goalContinuation/mailbox/synthetic), `guided?`, `attachments?: [{ref, fileName, mime, bytes, previewRef?}]`, `clientId?` |
| `assistantText` | `text`, `state` (streaming/complete/interrupted/failed), `model?`, `feedback?: "like"\|"dislike"` |
| `reasoning` | `text`, `state` (streaming/complete/interrupted), `durationMs?` |
| `toolCall` | `toolCallId`, `toolName`, `status` (inputStreaming/pendingApproval/running/success/error/cancelled), `inputText`, `input?`, `output?: {text, truncated?}`, `error?: {code, message}`, `progress?`, `approvalInteractionId?`, `backgrounded?`, `workId?` |
| `subagent` | `parentToolCallId?`, `subagentType`, `status`, `summaryText`, `childSessionId?` |
| `timelineMarker` | `marker`: `compact` / `forkNotice` / `forkCreated` / `modelChange` / `goalSet` / `goalVerify` / `retryNotice` / `checkpointRestored` |

### Deltas ops

`row.appended {row}` · `row.upserted {row}` · `row.removed {fromRowId}`
(truncate from that id) · `row.delta {rowId, path: string[], append}` (append
text at `path`, e.g. `["text"]`) · `state.updated {patch}` (partial snapshot
fields — deep-merge objects, replace leaves).

## Sessions-index snapshot & deltas

Snapshot `{protocolVersion:1, workspaceId, logEpoch, sessions:[…]}`; deltas
`session.upserted {session}` / `session.removed {sessionId}`. Session summary:

```
{ sessionId, workspaceId, parentSessionId?, title, titleSource?, phase,
  sessionEnded, hasBackgroundWork, pendingInteraction?: {interactionId, kind,
  toolName?, autoResolution?}, pendingInteractionSummary?, goalStatus?,
  lastActivityAt, lastAssistantPreview?, lastTerminalQuery?, createdAt }
```

## Workspace-config snapshot & deltas

Snapshot `{protocolVersion:1, workspaceId, logEpoch, config:{configOptions:[],
slashCommands:[]}}`; deltas `config.updated {config}`. Config option:
`{name, description?, category?, type:"select"|"boolean", currentValue,
options?: [{value, name, description?, origin?, modelProviderId?, …}]}`.

## Conversation commands

Send with `sendConversationCommandV4` (see 06 for the wrapper). Envelope:

```
{ commandId, clientId, sessionId (nullable, REQUIRED key), baseRevision?,
  baseLogEpoch?, type, payload, issuedAt }
```

Command types (payload shapes) — `baseRevision`/`baseLogEpoch` required for
commands marked ✎ (optimistic concurrency against the live session):

| type | payload | notes |
|------|---------|-------|
| `createSession` | `{workspaceId, firstInput?:{text, attachments?}, config?, runtimeModel?, mcpServers?}` | result `{type:"createSession", sessionId}` |
| `createSelectionSideSession` | `{}` | |
| `sendText` | `{text, attachments?, browserAmbientContext?, heldQueueDisposition?, expectedHeldQueueItemIds?, turnRuntimeModel?, toolDisallowlist?}` | ✎ |
| `sendGoalCommand` | `{text, displayText?, heldQueueDisposition?, …}` | ✎ |
| `stop` | `{expectedForegroundExecutionId?}` | interrupt current turn |
| `compact` | `{}` | |
| `forkAssistant` ✎ | `{target}` | result `{type:"forkAssistant", sessionId}` |
| `applyFileRewind` ✎ | `{target}` | result `{applied, preview, response}` |
| `editUserQuery` ✎ | `{target, newText, attachments?, workspaceMode?}` | result `{disposition: rewind\|fork\|blocked, sessionId, reasonCode?, preview?}` |
| `retryTurn` ✎ | `{target}` | |
| `setAssistantFeedback` ✎ | `{target, feedback: "like"\|"dislike"\|null}` | |
| `sendQueuedNow` | `{queueItemId}` / `editQueueItem {queueItemId,newText}` / `reorderQueueItem {queueItemId,beforeQueueItemId}` / `deleteQueueItem {queueItemId}` / `setAutoDrain {autoDrain}` | queue ops |
| `resolveInteraction` | `{interactionId, answer: {optionId?, freeText?, action?: accept\|decline\|cancel, content?}}` | result `{type:"resolveInteraction", resolvedBy:{clientId, optionId?}}` |
| `snoozeInteractionAutoResolution` | `{interactionId}` | |
| `switchModelConfig` | `{provider, model, thought, runtimeModel?}` | ✎ |
| `switchCollaborationMode` | `{mode: build\|edit\|plan\|yolo}` | |
| `setFollowupMode` | `{mode: queue\|guide}` | |
| `pauseGoal` / `resumeGoal` | `{}` | |
| `cancelBackgroundWork` | `{workId}` | |
| `renameSession` | `{title}` | ✎ — prefer the `zcode-task.renameTask` RPC (no base needed) |
| `deleteSession` | `{}` | ✎ — prefer `zcode-task.deleteTask` |

`target` = row selector `{rowId, entityId?}`.

Command result:

```
{ commandId, status: "accepted"|"rejected"|"stale"|"duplicate"|"noop"|"failed",
  reasonCode?, message?, revisionAtDecision, result? }
```

Statuses other than `accepted` are non-throws: `stale` = base revision mismatch
(refresh and retry), `duplicate` = commandId already seen (idempotent retry).

`queryConversationCommandsV4 {commands:[{sessionId, commandId}]}` → per-command
last result (or `"unknown"`).

## Reads

| RPC | Args | Returns |
|-----|------|---------|
| `conversationRowsRangeV4` | `{sessionId, beforeRowId?, limit ≤ 200}` (+ workspace target) | `{rows:[…], atSeq, atLogEpoch, hasMore}` |
| `conversationPlansV4` | `{sessionId}` | `{plans:[toolCall rows], atSeq, atLogEpoch}` |
| `conversationFileChangesV4` | `{sessionId, target, baseRevision, baseLogEpoch}` | `{files, additions, deletions, items:[{path, additions, deletions, writeCount, toolNames, patches:[{oldStart,oldLines,newStart,newLines,lines}]}]}` |
| `conversationFileRewindPreviewV4` | same | `{canApply, ignoredFiles, safeFiles, unsafeFiles}` |
| `getTaskTokenUsage` (zcode-agent) | `{sessionId}` (+ target) | `{sessionId, totalTokens, inputTokens, outputTokens, reasoningTokens, cacheCreationTokens, cacheReadTokens, modelRequestCount, modelErrorCount, inputBaselineBySource}` |

## Attachments (upload)

1. `attachmentBeginV4 {connectionId, uploadId, sessionId, fileName, mime,
   totalBytes ≤ 20 MiB, totalChunks ≤ 64, checksum:"sha256:<64 hex>"}` →
   `{uploadId, state:"staging", nextChunkIndex:0}`
2. `attachmentChunkV4 {connectionId, uploadId, sessionId, chunkIndex,
   dataBase64 ≤ 512 KiB decoded}` → `{uploadId, nextChunkIndex}` (in order)
3. `attachmentCommitV4 {…}` → `{uploadId, state:"committed", nextChunkIndex, ref}`
   — `ref` is what goes into `attachments[].ref` of `sendText`
4. `attachmentAbortV4` cancels.
   Download: `attachmentReadV4 {sessionId, ref, offset, limit ≤ 512 KiB}` →
   `{dataBase64, mediaType, totalBytes, nextOffset|null}`.
