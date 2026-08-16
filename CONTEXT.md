# ZCode Remote (Flutter)

A native Android client that replaces the ZCode web remote-control page: it pairs with a ZCode desktop app via QR scan and lets the user watch and drive coding sessions from the phone.

## Language

**Device**:
A computer running the ZCode desktop app. One phone can hold multiple pairings, one per device.
_Avoid_: machine, desktop (desktop is an adjective here), 电脑

**Pairing**:
The phone↔device binding established by scanning the QR code shown in the desktop app. The QR encodes a credential URL (`sid` + `hash`); a pairing is that credential plus the device's name and machine id.
_Avoid_: connection, session link, 配对链接

**Relay**:
The z.ai-hosted WebSocket service (`wss://zcode.z.ai/ws`) that both ends connect to. The relay matches a device with its terminals and forwards frames between them.
_Avoid_: server, gateway, 中转服务 (when writing in English)

**Terminal**:
A client that controls a device through the relay after authenticating with a pairing's credentials. The phone app acts as a terminal.
_Avoid_: client (ambiguous), controller, 控制端

**Workspace**:
A project directory the desktop app has open. The phone can only see workspaces that are open on the device, and connects to one workspace at a time.
_Avoid_: project (broader concept), 工作区 vs 项目

**Session**:
One agent conversation inside a workspace, identified by a session id. A workspace can run several sessions in parallel; sessions persist after they end.
_Avoid_: task, conversation thread, 会话

**Conversation**:
The ordered stream of rows that makes up a session's history — user inputs, assistant text, reasoning, tool calls, subagent activity, timeline markers.
_Avoid_: chat log, 对话流

**Bridge**:
The RPC channel between the terminal and one workspace after pairing. Switching workspaces means closing one bridge and opening another.
_Avoid_: connection, pipe, 桥接

**Approval**:
An in-conversation interaction where the agent waits for the user — permission for a tool call, or an answer to a question. Presented as a card with accept/decline (or option buttons).
_Avoid_: confirmation dialog, prompt, 批准卡

**Stop**:
The command that interrupts the agent's current turn (the phone equivalent of Ctrl+C).
_Avoid_: cancel, kill, 打断

**Foreground service**:
The Android mechanism that keeps the app's connection alive while it is in the background, so notifications stay real-time.
_Avoid_: background service, 常驻

**Row**:
A single entry in a conversation (user input, assistant text, tool call, …), with a row id and a turn id. Rows arrive incrementally — appended, upserted, delta-patched — never as a whole list.
_Avoid_: message (messages are user input only), 行/消息

**Snapshot & deltas**:
The two delivery modes for conversation state: a full snapshot on subscribe, then incremental deltas (row appended, row delta text, state patch) while subscribed.
_Avoid_: initial load, 全量/增量

## Boundary

Out of scope for v1: usage/billing UI, browser control, terminal panel (xterm), Z.AI account login. The conversation UI is the product. Model provider management (model-provider channel) and model/thought selection for new sessions are in scope (added 2026-08-16); held-queue management is deferred until event push delivers queue state.
