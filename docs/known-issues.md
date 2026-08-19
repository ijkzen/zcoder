# 已知问题（Known Issues）

> 记录当前已定位但**尚未修复**的连接/通知相关问题。每条含症状、根因、证据（文件:行号）、
> 候选方案与状态。修复仅在根因经日志确认后进行（见文末「排查与确认」）。
>
> 修订：2026-08-19 初版，来源为 8 月 19 日会话排查（用户实测复现）。

## 问题 1：后台断连时不发「连接中断」通知（通知被过早撤销）★待修

**症状**：连接断开时（尤其是 App 处于后台），用户收不到系统通知；回到前台才在 App 内看到
「连接已断开，正在尝试重连…」横幅。UI 契约 TC-GLOB-004 要求按原因弹出断连通知，此处未满足。

**根因**：取消断线通知的时机挂在 `BridgePhase.ready` 上，而 `ready` 只代表 **relay 重新配对成功**，
不代表 **bridge 恢复健康**。典型时序：

1. relay WebSocket 断开 → `failureStream` 发出失败 → 弹出「连接中断」通知
   （`relay_client.dart` `_onSocketClosed` → `app_controller.dart:156-158` → `notifications.dart:182`）。
2. 手机网络正常时 relay 秒级重连、重新 `paired` → `bridge_manager.dart:142` `_setPhase(ready)`。
3. `app_controller.dart:137` 见 `ready` 即调 `cancelReconnectNotification()` → **通知 1~2 秒内被撤销**。
4. 但 bridge 实际仍处于降级（`isDegraded`），恢复循环最多重试约 4.5 分钟且**失败只 zlog、不补发任何
   错误事件**（`bridge_manager.dart:367-413`）→ 通知不会重新出现。

最终后台用户等于全程无通知，只有 App 内横幅（依据 `app_controller.dart:120 isReconnecting`，
`isDegraded` 未解除所以横幅仍在）。

**次级 bug（同源反向）**：走 `transport-fault`/`bridge-degraded` 路径时（relay 未掉线）
`recoveredStream` 只触发 `notifyListeners()`（`app_controller.dart:162`），**恢复成功后不取消通知**，
「连接中断」通知会残留。

**候选方案**：
- 把「取消断线通知」从 `BridgePhase.ready` 改为真正的健康信号：`recoveredStream`（恢复完成）与
  手动 `disconnect()` 时取消；`ready` 时若 `isDegraded` 仍为真则**不取消**。
- 断线通知改为更高重要度（`_channelQuiet` 目前是 `defaultImportance`/无声音无 heads-up，
  `notifications.dart:35`），因为它语义上就是后台提醒。

## 问题 2：App 一进后台就稳定断连 ★待修（主要依赖系统层豁免）

**症状**：手机 App 放入后台（锁屏/切走）几乎稳定触发断连，回前台网络恢复后重连。

**根因**：**非 App 主动断开**——已确认无任何代码在生命周期变化时关闭连接
（`main.dart:67` 只设 `isForeground`；`stopForegroundTask()` 定义但从未调用）。实际是系统省电机制：

- Android Doze 在屏幕关闭+静止后封锁 App 网络；本 App 虽有前台服务（`dataSync`）与唤醒锁
  （flutter_foreground_task `allowWakeLock` 持有 `PARTIAL_WAKE_LOCK`，见其
  `ForegroundService.kt:428`），**但不豁免 Doze 的网络封锁与部分唤醒锁忽略**。
- 心跳 30 秒无 `pair_status_ack` → `relay_client.dart:345-350` `_socket?.close()` → 判定连接已死 →
  进入重连；重连在 Doze 期间同样失败。
- Manifest **未申请** `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`，也未引导用户开启后台无限制/自启动；
  国产 ROM 对后台冻结更激进，可能更快触发。

**候选方案**：
- 申请 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + 在设置页引导用户把本 App 电池改为「不受限制」、
  允许自启动/后台运行。
- 快速验证法：设置里给 App 电池「无限制」后复测；若不再断，即实锤系统层。

## 问题 3：唯一手机控制端却被通知「被其他设备接管」（自抢线误判）★待确认根因

**症状**：自始至终只有本手机远程连接，断线后系统通知却显示「已被其他设备接管」。

**根因（强假设，待日志确认）**：中继强制**同一配对同一时刻仅一台终端**（
`docs/protocol/01-relay-transport.md:82` KICKED、`:93` close 4009）。单手机时出现该错误，是
**重连自抢线**：

1. 后台断网（问题 2）→ 心跳超时关 socket → 重连持续失败。
2. 回到前台/网络恢复 → 某次重连成功。
3. 服务器仍认为旧连接存活（TCP 半开假死、服务端尚未感知）→ 判定「第二终端」→ 把新连接踢掉并发
   `KICKED`。
4. 手机端把 KICKED 视为 fatal（`relay_client.dart:232-238` `_userClosed=true`，不再自动重连，
   防真接管死循环）→ 断线持续，需手动重连。

已排除 App 侧第二终端可能：`connectTo` 前必先 `disconnect()`（`app_controller.dart:123-125`），
启动不自动连接，无并发连接逻辑。

注：KICKED 后 `phase=failed`，永远不回到 `ready`，通知不会被问题 1 的撤销逻辑撤掉——这也是本问题
通知能显示、而问题 1 通知看不见的对照证据。

**候选方案**：
- KICKED 后延迟数秒做**有限次重试**（如最多 3 次）：重连成功 = 自抢线；继续被踢 = 真被接管才停，
  与「防止真接管死循环」平衡。
- 或至少在此场景提示用户可手动重连。
- 服务端 KICKED 判定细节在本仓库之外（z.ai relay），只能从客户端侧缓解。

## 排查与确认（当前待办）

- **另一会话正在为本 App 增加文件日志系统**；落地后用于确认上述根因：
  - 问题 3：对照时间线——上一次 socket 关闭时刻（约 30 秒心跳超时）与 KICKED 到达时刻是否紧挨
    重连成功那一刻。
  - 问题 1：确认通知弹出→撤销的时间窗与 `ready` 相位关系。
  - 问题 2：确认重连尝试的节律与失败时长。
- **根因经日志确认后**再实施修复（问题 1 与问题 3 的候选方案可直接落地）。

## 日志埋点（2026-08-19 已加，全部走 zlog → 日志页 + 落盘文件）

> 排查时按 `[relay]`/`[bridge]`/`[notify]`/`[zremote]` 前缀或以下关键字筛文件日志，重建时间线。

| 观测点 | 位置 | 关键字 | 回答什么 |
|--------|------|--------|----------|
| relay 状态迁移（含配对/重连/关闭） | `relay_client.dart` `_setState` | `relay state ->` | 何时配对、何时重连 |
| socket 关闭细节 | `relay_client.dart` `_onSocketClosed` | `websocket closed:` code/reason | 问题 3：close code 是 4009/4010 还是网络断 |
| 心跳超时强制关 | `relay_client.dart` 心跳定时器 | `heartbeat ... 无 ack` | 问题 2：Doze 下链路僵死点 |
| 重连计划（指数退避） | `relay_client.dart` `_scheduleReconnect` | `scheduling reconnect attempt` | 问题 2：重连节律与失败时长 |
| 致命错误停止重连 | `relay_client.dart` RelayError 分支 | `视为致命` | 问题 3：KICKED/AUTH_FAILED 现身时刻 |
| bridge 重连上下文 | `bridge_manager.dart` `_onRelayState` | `relay reconnecting` | ready/degraded 与重连的关系 |
| bridge 恢复完成 | `bridge_manager.dart` `_finishRecovery` | `recovery complete` | 问题 1：恢复点 vs 通知撤销点 |
| 桥相位（zlog 化，原 debugPrint） | `app_controller.dart` `_phaseSub` | `bridge phase ->` | 全生命线主坐标 |
| ready 仍降级告警 | `app_controller.dart` `_phaseSub` | `仍降级` | 问题 1：取消通知的瞬间 bridge 是否健康 |
| relay 失败原因 | `app_controller.dart` `_relayFailureSub` | `relay failure:` | failure→通知 的映射 |
| 恢复完成（UI 层） | `app_controller.dart` `_recoveredSub` | `bridge recovered` | 问题 1：恢复未取消通知的反向残留 |
| 主动断开 | `app_controller.dart` `disconnect()` | `disconnect() 主动断开` | 区分用户手动断开 vs 被动掉线 |
| 断线通知弹出 | `notifications.dart` `_handleBridgeEvent` | `断线通知:` reason/id | 问题 1：通知到底弹没弹 |
| 断线通知撤销 | `notifications.dart` `cancelReconnectNotification` | `撤销断线通知 N 条` | 问题 1：撤销时机与条数 |

**复现方法**：release 或 debug 均可（`ZREMOTE_LOG=true` 时额外进 logcat）。把 App 放后台触发断连，
回前台确认横幅，然后 `adb pull /sdcard/Android/data/<pkg>/files/zremote_2026-08-19.log` 或从
App 内协议日志页导出，按上面关键字还原时间线。
