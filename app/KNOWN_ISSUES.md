# 已知遗留问题

## 0.（已修复 2026-08-16）权限审批弹窗无可用 UI：空页 + RangeError

**状态**：已修复并真机回归。`_RequestSheet` 提取为独立 `lib/src/ui/request_sheet.dart`（public RequestSheet），新增三类页面：权限页（reason/riskLevel/toolName + options 单选，提交 `{optionId}`，取消选 deny 选项）、自由文本页（prompt + 输入框/简单选项，提交 `{freeText}`/`{optionId}`）、提问页（原逻辑不变，`buildQuestionAnswerContent` 与桌面 renderer `_xt` 一致）；「提交」一次性结算全部已作答页面，未作答的权限保持挂起（runtime 到点自动解析）。分类 getter 新增 `isFreeTextInput`/`isExitPlanMode`（`freeText:true` 才是自由文本，普通工具参数里的 prompt 键不会误判）。测试 14 个新增（分类 6 + sheet 8），全套 75/75，真机连上无异常。审计记录见 docs/protocol/07「Interaction resolution audit」。

## 1.（E2E 定论 2026-08-16，clientKind 复核 2026-08-16）事件推送（204/wire frame）对终端连接不投递，双结论成立

**状态**：v0.5 重构后真机 E2E 定论——两个结论同时成立：① 旧解析器形状确实错误（`onDynamic*Frame` 投递的是 wire frame `{wireVersion:3, kind:"complete"|"fragment"}`，旧代码按 `kind: topic-frame` 解析，任何到达的帧都会被丢弃）——v0.5 已按 asar 权威 schema 重写（`lib/src/protocol/topics/wire_frame.dart`，complete 直通/fragment 按 logicalFrameId 重组+CRC32）；② 即便解析正确，**204 事件帧依然不会到达终端连接**（E2E 全程零 wire frame 日志、零 unknown-kind 日志，所有入站消息均为 RPC 响应；桌面侧 3 个事件订阅均注册成功，但无任何推送到达）。v0.4.0「relay 按浏览器特性投递」的结论维持，解析修复是必要但不充分条件。**数据通路维持 readSession + conversationRowsRangeV4 双轮询**（E2E 验证 2s/6s 节奏稳定、会话页/对话页实时渲染含工具调用与思考过程）。wire-frame 解析层保留：若未来推送恢复，无需再改协议代码。

**clientKind 复核实验（2026-08-16）**：对照 zemote（clientKind=`mobileApp`、appVersion 3.6.5，纯推送无轮询）把 clientHello 从 `mobileRemote`/3.4.0 改为 `mobileApp`/3.6.5，真机 E2E 复核——桌面侧 `onDynamicConversationFrame/SessionsIndexFrame/WorkspaceConfigFrame` 三个订阅依旧注册成功、`subscribeConversationV4 OK`，但**依旧零 wire frame 到达终端**（app 侧零 `wire frame delivered` 日志，桌面日志无任何 eventFire）。推送缺失与 clientKind/appVersion 无关，维持「relay 按浏览器特性投递」定论。**推论**：CAS 命令（retryTurn/editUserQuery/队列等）无可靠 revision/logEpoch 来源，按不带 base 实施（沿用 `_sendCommand` 的 hasSnapshotBase 守卫）；会话列表数据源维持 workspace-list tasks（sessions-index 同样收不到推送，不更实时）。

## 2. 桌面命令通道偶发无响应（sendText/createSession/deleteSession 的 RPC 不返回）

**状态**：已缓解（2026-08-16 阶段 1 实施 bridge 恢复循环）。桌面 runtime 重启窗口期（relay 重连、agent 进程 spawn 频繁时）命令 RPC 可能不返回；命令本身已执行（任务列表可见结果）。新增机制：① relay 重连/transport 故障时 bridge 进入 degraded 状态，命令先 `waitHealthy`（45s）等待恢复而非直接失败；② 恢复流程 `workspace-reconnect-request` → 失败则 reopen（新 identity + generation+1 + recoveryId 换栈）→ 恢复后会话自动重订阅；③ 命令超时后仅当 bridge 确实 degraded 才用新 commandId 重试一次（健康桥超时重试会重复投递，直接抛出）。残留：恢复循环 15 次 × 3s 内仍未恢复时命令仍会超时；桌面端彻底卡死场景无解。App 侧发送/创建保留 15 秒超时，超时提示"发送失败"但命令实际已生效——极端情况下可能重复发送。

## 4.（2026-08-16 决策）队列管理 UI 后置：推送断供导致无数据源

**状态**：已决策暂缓。held queue（items/autoDrain）与 `inputRouting` 均来自会话 snapshot（事件推送），而 204/wire-frame 对终端连接不投递（见条目 1）；`conversationRowsRangeV4` 响应已实证只内联 `control`/`meta`/`pendingInteractions`（docs/protocol/07），无 queue/inputRouting。没有 queueItemId 就无法调用队列命令（sendQueuedNow/editQueueItem/deleteQueueItem/setAutoDrain），故整组功能等待推送恢复或 rowsRange 内联扩展后再做。协议侧无需改动。

## 3. 运行中会话的 readSession 偶发 `Session is not active`

**状态**：已知。runtime 只对当前连接的会话保持 active；探针/网页端连接断开后会话被卸载，再读会报错。App 打开会话时始终轮询，不受影响。会话的 contextUsage `breakdown`（分类占比）只在运行中会话返回，已完成的会话只有 used/size 与 cache。

## 5.（2026-08-16 真机回归修复）长按消息菜单被文本选择抢占 + 斜杠面板触发条件过严

**状态**：已修复并真机回归。① `_LongPressRow` 原用 `GestureDetector.onLongPress` 包裹行内容，与 `SelectableText` 的文本选择长按在手势竞技场竞争失败——长按只触发文本选择（Copy/Share 菜单），「重试回合/编辑重发」菜单永远不出现。改为 `Listener` 指针计时（500ms）实现，不参与竞技场，长按必弹操作菜单（真机实证「重试回合」菜单弹出）；tap/文本选择不受影响。② 斜杠面板触发条件 `token.length > 1` 导致单独输入 `/` 不弹面板——去掉长度限制，输入 `/` 立即显示全部命令（真机实证 4 个 slashCommands 正常弹出）。

## 6.（2026-08-16）会话页屏幕常亮

会话详情页 `initState` 启用 `WakelockPlus.enable()`、`dispose` 禁用——长时间驱动 agent 不会被系统锁屏打断（依赖 `wakelock_plus ^1.7.0`）。

## 7.（2026-08-17 已完整验证）断网自动重连与 bridge 恢复

真机 E2E 完整通过（USB adb，Wi-Fi 断开 35-50s 两轮）：`relay dropped while bridge open — degrading` → 出站排队（queued payload）→ relay 自动重连 + 重放未 ack（replayed 2 unacked）→ `workspace-reconnect-request`（桌面拒绝：远程 workspace 不在当前窗口）→ 回退 reopen（gen+1、新 identity、recoveryId）→ `bridge reopened` → **会话自动重订阅（conversation resubscribed after bridge recovery）**。两轮断网均完整恢复，命令与轮询（rowsRange/readSession）恢复后正常。注意：Wi-Fi adb 与手机网络共用链路，断网测试请用 USB 连接。

## 8.（2026-08-17 修复）首次连接后打开项目报「打开项目失败：未知错误」（必现：第一次点击必失败，第二次点击必成功）

**现象**：冷启动连接设备后**第一次**点击项目必显示"打开项目失败：未知错误"，**第二次**点击必成功（bridge 实际已打开，早退分支通过）。

**根因**（探针日志铁证 02:02:33.441）：`StreamController.broadcast()` 默认**异步分发**——`BridgeManager._setPhase(ready)` 里 bridge 内部 `_phase` 已同步更新，但 `phaseStream.add(ready)` 只是入队，`AppController._phase` 要等微任务才更新。`workspaces_page._open` 在 `selectWorkspace` 返回后立即检查 `app.phase`，读到的是旧的 connecting → 误报失败；微任务执行后 phase 变 ready，第二次点击走早退分支成功。日志顺序：`bridge done, phase=CONNECTING` → `phase check failed` → `bridge phase: READY`（ready 事件在检查之后才送达）。

**修复**：① `BridgeManager._phaseController` 改 `broadcast(sync: true)`——phase 事件同步送达，`selectWorkspace` 返回时 `app.phase` 必为 ready；② `RelayClient._stateController` 同样改 sync（否则 `_waitForRelayReady` 可能错过已分发的 `matched` 事件，20s 超时）；③ 附带加固：`selectWorkspace` 在 relay 未就绪时等待（≤20s）而非立即抛 `invalid-state`、等待在途恢复循环结束、`_open` 加 try/catch 显示真实错误、`bridge == null` 抛「未连接桌面端」。真机验证：冷启动首次点击直接进入会话列表（日志 `bridge done, phase=READY → pushing SessionsPage`）。

## 9.（2026-08-17 修复）每个项目只显示一个会话

**根因**：`WorkspaceListData.mergedEntries` 按 workspaceKey 去重，而同一项目的多个会话共享 workspacePath——同项目任务被合并成一条（每个项目只剩第一个会话）。

**修复**：任务条目全部保留（每个 task 即一个会话），workspace 条目只填补没有任务覆盖的 key。新增单测（同 workspace 3 个任务全保留）。

## 10.（2026-08-17）模型弹窗协作模式

- **当前值来源**：`prepareWorkspace` configOptions 只有 model/mode/thought_level；`readWorkspaceState` settings 有 `mode: {current: yolo}`（实证）——协作模式选中值取 `settings.mode.current`（会话详情页用 readSession、会话列表页用 readWorkspaceState），chips 乐观更新即时高亮。
- **跟随模式已删除**：`followupMode` 无任何 settings/configOptions 数据源（仅在会话 snapshot，推送断供）——按用户要求从弹窗删除；协议命令 `setFollowupMode` 保留。
- 会话列表输入框上方标签行：模型 · 思考 · 协作模式纯值展示（无图标/描述文本）。
