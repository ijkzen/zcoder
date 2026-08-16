# Layer 5b — Service inventory (channels exposed over the bridge)

After `workspace-bridge-ready`, the device attaches the workspace's host
process to the bridge and exposes its services over layer 4. A terminal can
call any of them; the ones the web remote page actually uses are the `zcode-*`
channels. Source: `RemoteServiceAccess` channel list in
`out/main/chunk-73KAKK7G.js`, service definitions in `out/host/index.js` [asar].

Every method takes a **workspace target** object as its single argument:
`{workspacePath, workspaceIdentity?}` (for conversation-shaped calls also
`sessionId`/`taskId`). Some V4 methods additionally validate a nested
`workspace: {workspacePath}` object — when in doubt send both (probe-verified).

## Channel registry

`file`, `system`, `terminal`, `git`, `git-checkpoint`, `setting`, `credential`,
`broadcast`, `zcode-task`, `zcode-agent`, `zcode-session`, `file-watcher`,
`oauth`, `model-provider`, `usage-stats`, `coding-plan-subscription`, `skills`,
`skill-sync`, `mcp-sync`, `plugin-sync`, `plugins`, `plugin-management`,
`subagents`, `commands`, `hooks`, `memory`, `output-style`, `settings-sync`,
`bots`, `feedback`, `repo-wiki`, `prompt-attachment-transfer`, `off-peak-task`.

## `zcode-agent` — 68 methods

V4 data plane (documented in [05](05-v4-conversation-data-plane.md)):
`helloConversationV4`, `initializeConversationV4` (clientHello:
`{kind:"clientHello", protocolVersion:3, clientId, clientKind?:
"desktop"|"web"|"mobileRemote"|"mobileApp", appVersion}`),
`setConnectionFlowStateV4`, `subscribeConversationV4` /
`unsubscribeConversationV4` / `resyncConversationV4`, `sendConversationCommandV4`,
`queryConversationCommandsV4`, `attachmentBeginV4` / `attachmentChunkV4` /
`attachmentCommitV4` / `attachmentAbortV4` / `attachmentReadV4`,
`conversationRowsRangeV4`, `conversationPlansV4`, `conversationFileChangesV4`,
`conversationFileRewindPreviewV4`, `subscribeSessionsIndexV4` /
`unsubscribeSessionsIndexV4` / `resyncSessionsIndexV4`,
`subscribeWorkspaceConfigV4` / `unsubscribeWorkspaceConfigV4` /
`resyncWorkspaceConfigV4`, `resolveRuntimeModelForV4`.

Events (dynamic unless noted): `onDynamicConversationFrame(target)` — wire
frames for every subscribed conversation topic; `onDynamicSessionsIndexFrame`
/ `onDynamicWorkspaceConfigFrame`; `onDynamicSessionEvent({…, sessionId,
deliveryKind, includeSnapshot})` — raw session stream incl. snapshots;
`onDynamicConversationTelemetryFact`; `onDynamicSessionRuntimePreferencesRequest`;
`onDynamicProviderRuntimeHeadersRequest`; `onDynamicProcessResourceSample`;
`onAgentRuntimeRestarted`; `onAgentRuntimeLifecycle`.

Other methods: `sendPrompt`, `compactSession`, `goalSession`, `closeSession`,
`upsertModelProvider`, `removeModelProvider`, `updateProviderRegistry`,
`setWorkspaceDefaultModel` / `…ThoughtLevel` / `…Mode`, `setModel`,
`setThoughtLevel`, `updateRuntimeModelConfig`, `setMode`,
`respondSessionRuntimePreferences`, `respondProviderRuntimeHeaders`,
`getAppUsageStats`, `getTaskTokenUsage`, `readSession`, `readSessionMessages`,
`readSessionEvents`, `readWorkspaceState`, `createSession`, `resumeSession`,
`listSessions`, `listSessionSubagents`, plugin & automation management
(`listPlugins`, `installPlugin`, `uninstallPlugin`, `updatePlugin`,
`configurePlugin`, `setPluginEnabled`, marketplace ops, `listAutomations`,
`runAutomationNow`, …), `generateWorkspaceText`, `disposeWorkspace`,
`disposeAllAndWait`.

## `zcode-task` — terminal-facing task facade, 67 methods

Workspace/session lifecycle: `initialize`, `prepareWorkspace` (→
`{workspacePath, configOptions, slashCommands}`),
`releaseWorkspacePreparation`, `checkCodexConnectivity`, `createTask`
(`{…, draftSessionId?, model?, thoughtLevel?, v4Create?}` →
`{taskId, sessionId}`), `resumeTask`, `closeTask`, `switchAgent`.

Task list queries: `listTasks`, `listPinnedTaskIds`, `listPinnedTasks`,
`listDeletedTaskIds`, `listTaskList`, `listArchivedTasks`, `listGroupedTaskViewStructure`,
`getTaskSnapshot` / `getTaskSnapshotWithEtag` / `getTaskSnapshotBody` /
`getTaskSnapshotRef` / `getTaskSnapshotToolCallsSlice`, `getTaskMeta`,
`getTaskConfigOptions`, `getTaskTokenUsage`, `getTaskNativeSessionLogFile`,
`getTaskSessionFilePath`, `getModelTrajectory`, `getWorkspaceProviderConfigFile`.

Mutations: `sendPrompt`, `deliverSessionMessage`,
`sendSessionMessageDeliveryResult`, `enqueueTaskCommand`, `promoteTaskCommand`,
`cancelTaskCommand`, `stopGeneration`, `compactSession`, `goalSession`,
`respondPermission`, `respondElicitation`, `renameTask`, `deleteTask`,
`setTaskPinned`, `setTaskUnread`, `archiveTask`, `unarchiveTask`,
`archiveStaleTasks`, `archiveWorkspaceTasks`, `branchTaskFromPrompt`,
`setAssistantMessageFeedback`, `syncTaskSessionBinding`, `setMode`,
`setConfigOption`, `setModel`, `setAutomationSessionConfig`,
`setWorkspacePreferredModel` / `…Mode` / `…ThoughtLevel` (+
`getWorkspacePreferredMode` / `…ThoughtLevel`), task groups (`createTaskGroup`,
`renameTaskGroup`, `updateTaskGroupColor`, `deleteTaskGroup`,
`applyGroupedTaskViewOrder`), `scanImportableClaudeSessions`,
`importClaudeSessions`, `restartWorkspaceProcess`, `disposeAllAndWait`.

Events: `onDynamicStreamEvent(target)`, `onDynamicTaskTerminalOutcome(taskId)`
(→ `{taskId, inputId?, outcome:"succeeded"|"failed"}`),
`onDynamicTaskReady(taskId)` (→ `{taskId, reason}`), `onDynamicTaskEvent({taskId,
…, deliveryKind:"replayable"|"continuous", includeSnapshot})`,
`onDynamicWorkspaceEvent(target)`, `onError` (static).

Stream events (what `onDynamicStreamEvent`/task events carry) include:
`permission_request {taskId, traceId, requestId, description, kind, title,
options, origin?, raw}`, `elicitation_request {taskId, traceId, requestId,
message, header, questions, …}`, plus mirror events
(`task_snapshot_invalidated`, `workspace_task_list_invalidated`,
`task_stream_mirror_batch {ops:[user_message|stream_event], fromSeq, toSeq,
terminal}`) and task lifecycle (`task_created`, `task_status_changed`,
`task_meta_changed`, `task_model_changed`, `task_title_changed`, `task_pinned`,
`task_unpinned`, `task_archived`, `task_unarchived`, `task_deleted`,
`user_message_saved`, `assistant_message_saved`, `stream_mirror_gap`,
`stream_mirror_owner_lost`).

## `zcode-session` — 27 methods

`initializeWorkspace`, `getWorkspaceRuntimeIdentity`, `readWorkspaceState`,
`createSession`, `resumeSession`, `listSessions`, `readSession`
(`{sessionId, deliveryKind?, messageLimit?, afterSeq?}` →
`{session:{status: running|idle|error, …}, settings:{model, thoughtLevel},
runtime:{contextUsage}, projection:{pendingPermissions}, messages?}`),
`readSessionMessages`, `readSessionEvents`, `promoteDeferredDraftSession`,
`closeSession`, `closeDeferredDraftSession`, `upsertModelProvider`,
`removeModelProvider`, `updateProviderRegistry`, `resolveRuntimeModelForV4`,
`setWorkspaceDefaultModel` / `…ThoughtLevel` / `…Mode`, `setModel`
(`{sessionId, model:"provider/model", thoughtLevel?}`),
`setThoughtLevel`, `setMode`, `respondProviderRuntimeHeaders`.
