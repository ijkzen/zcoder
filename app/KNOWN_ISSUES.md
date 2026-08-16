# 已知遗留问题

## 0.（已修复 2026-08-16）权限审批弹窗无可用 UI：空页 + RangeError

**状态**：已修复并真机回归。`_RequestSheet` 提取为独立 `lib/src/ui/request_sheet.dart`（public RequestSheet），新增三类页面：权限页（reason/riskLevel/toolName + options 单选，提交 `{optionId}`，取消选 deny 选项）、自由文本页（prompt + 输入框/简单选项，提交 `{freeText}`/`{optionId}`）、提问页（原逻辑不变，`buildQuestionAnswerContent` 与桌面 renderer `_xt` 一致）；「提交」一次性结算全部已作答页面，未作答的权限保持挂起（runtime 到点自动解析）。分类 getter 新增 `isFreeTextInput`/`isExitPlanMode`（`freeText:true` 才是自由文本，普通工具参数里的 prompt 键不会误判）。测试 14 个新增（分类 6 + sheet 8），全套 75/75，真机连上无异常。审计记录见 docs/protocol/07「Interaction resolution audit」。

## 1.（E2E 定论 2026-08-16）事件推送（204/wire frame）对终端连接不投递，双结论成立

**状态**：v0.5 重构后真机 E2E 定论——两个结论同时成立：① 旧解析器形状确实错误（`onDynamic*Frame` 投递的是 wire frame `{wireVersion:3, kind:"complete"|"fragment"}`，旧代码按 `kind: topic-frame` 解析，任何到达的帧都会被丢弃）——v0.5 已按 asar 权威 schema 重写（`lib/src/protocol/topics/wire_frame.dart`，complete 直通/fragment 按 logicalFrameId 重组+CRC32）；② 即便解析正确，**204 事件帧依然不会到达终端连接**（E2E 全程零 wire frame 日志、零 unknown-kind 日志，所有入站消息均为 RPC 响应；桌面侧 3 个事件订阅均注册成功，但无任何推送到达）。v0.4.0「relay 按浏览器特性投递」的结论维持，解析修复是必要但不充分条件。**数据通路维持 readSession + conversationRowsRangeV4 双轮询**（E2E 验证 2s/6s 节奏稳定、会话页/对话页实时渲染含工具调用与思考过程）。wire-frame 解析层保留：若未来推送恢复，无需再改协议代码。

## 2. 桌面命令通道偶发无响应（sendText/createSession/deleteSession 的 RPC 不返回）

**状态**：已知，缓解中。桌面 runtime 重启窗口期（relay 重连、agent 进程 spawn 频繁时）命令 RPC 可能不返回；命令本身已执行（任务列表可见结果）。App 侧发送/创建已加 15 秒超时，超时提示"发送失败"但命令实际已生效——极端情况下可能重复发送。待桌面端稳定后回归。

## 3. 运行中会话的 readSession 偶发 `Session is not active`

**状态**：已知。runtime 只对当前连接的会话保持 active；探针/网页端连接断开后会话被卸载，再读会报错。App 打开会话时始终轮询，不受影响。会话的 contextUsage `breakdown`（分类占比）只在运行中会话返回，已完成的会话只有 used/size 与 cache。
