# 已知遗留问题

## 1.（已解决）审批 / AskUserQuestion 在手机端无法出现 → 改用 readSession 轮询

**状态**：v0.4.0 已解决。事件推送（204 帧）确认永远到不了终端连接（官方浏览器页面可以、任何 Node/App 连接都不行，属 relay 按浏览器特性投递），因此改为 `zcode-session.readSession` 轮询拿到 `projection.pendingPermissions`（审批与 AskUserQuestion 都在里面，`requestId` 即 resolveInteraction 的 interactionId），配合 `conversationRowsRangeV4` 行轮询。UI 改为输入框上方的独立入口徽章（审批/提问/待办）+ 底部弹窗（进详情自动弹出，返回/点外部消失）。详见项目记忆 zcode-remote-flutter-project。

## 2. 桌面命令通道偶发无响应（sendText/createSession/deleteSession 的 RPC 不返回）

**状态**：已知，缓解中。桌面 runtime 重启窗口期（relay 重连、agent 进程 spawn 频繁时）命令 RPC 可能不返回；命令本身已执行（任务列表可见结果）。App 侧发送/创建已加 15 秒超时，超时提示"发送失败"但命令实际已生效——极端情况下可能重复发送。待桌面端稳定后回归。

## 3. 运行中会话的 readSession 偶发 `Session is not active`

**状态**：已知。runtime 只对当前连接的会话保持 active；探针/网页端连接断开后会话被卸载，再读会报错。App 打开会话时始终轮询，不受影响。会话的 contextUsage `breakdown`（分类占比）只在运行中会话返回，已完成的会话只有 used/size 与 cache。
