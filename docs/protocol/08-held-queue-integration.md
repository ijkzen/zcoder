# Layer 8 — 排队消息（held queue）接入指南

给本仓库（Flutter 客户端）补上「排队消息」功能的分步实现指南。协议事实以
[05-v4-conversation-data-plane.md](05-v4-conversation-data-plane.md) 为准，本文只
聚焦队列相关的协议面与落地代码。参考实现是同级项目 **zemote**（同协议、同
`clientKind: mobileApp`，事件推送与队列管理均已实测可用）——文末列了它的对应
文件/行号，可直接对照。

> 现状：本指南已按文末步骤全量落地（2026-08-17，commit 0b860b3），真机实测
> 收到桌面端发出的排队消息。此前「held-queue management is deferred until event
> push delivers queue state」与「事件推送对终端连接不投递」的结论均为**客户端
> bug**——见 §3.2 的根因定论。

---

## 1. 功能定义

会话运行中（agent 正在生成 / 执行工具），用户再发一条消息时，桌面端不立即执行
这条输入，而是放入 **held queue**（排队区）。客户端需要做到：

1. 运行时发消息 → 消息进入排队区（服务端持有，客户端展示）。
2. 看到排队区：消息列表 + 自动发送开关（autoDrain）。
3. 管理每一条排队消息：**立即发送**（插队）、**编辑**、**删除**、**排序**（可选）。
4. 按 `inputRouting.mode` 决定发消息时是否询问用户（`choice` 时弹窗）。

---

## 2. 协议事实（队列相关）

### 2.1 队列状态在会话快照里

`conversation/<sessionId>` 快照（snapshot）包含：

```
queue: {
  items: [ { queueItemId: string, text: string, ...其它字段原样透传 } ],
  autoDrain: boolean,      // 缺省视为 true
  pauseReason?: string
}
```

队列的**每次变化**（新增、编辑、删除、立即发送、autoDrain 切换）都会以
`state.updated` 增量推送：

```
deltas: [ { op: "state.updated", patch: { queue: {...} } } ]
```

`patch` 是**快照顶层字段的局部更新**（对象深合并、叶子替换），不只是 control——
这是本仓库现有代码唯一需要修正的协议细节（见 4.3）。

### 2.2 输入路由：`inputRouting.mode`

快照顶层字段 `inputRouting: { mode, reasonCode? }`，取值：

| mode | 运行时发消息会怎样 |
|------|--------------------|
| `startNow` | 直接开始（可打断当前回合） |
| `enqueue` | 自动排队 |
| `guide` | 走引导（followup guide） |
| `reject` | 拒绝发送（ack 带 reasonCode，客户端 toast） |
| `choice` | **让用户选**：排队发送 or 清空队列插队 |

客户端规则（与官方 web 客户端、zemote 一致）：**只有 `choice` 且队列非空时才弹
对话框**；其它 mode 直接发、不带 `heldQueueDisposition`。

### 2.3 发送命令的队列参数

`sendText` / `sendGoalCommand` payload 支持：

```
{
  text, attachments?, ...,
  heldQueueDisposition?: "keepQueueAndSend" | "clearQueueAndSend",
  expectedHeldQueueItemIds?: string[]   // 可选：期望当前队列 id，服务端 CAS 校验
}
```

- `keepQueueAndSend`：保留排队消息，新消息排到队尾。
- `clearQueueAndSend`：清空队列，新消息插队立即执行。

### 2.4 队列管理命令（全部是 CAS 命令，需 `baseRevision`）

| 命令 | payload | 说明 |
|------|---------|------|
| `sendQueuedNow` | `{queueItemId}` | 立即发送这条排队消息（插队） |
| `editQueueItem` | `{queueItemId, newText}` | 改文本 |
| `deleteQueueItem` | `{queueItemId}` | 删除 |
| `reorderQueueItem` | `{queueItemId, beforeQueueItemId}` | 移到指定项之前 |
| `setAutoDrain` | `{autoDrain}` | 自动发送开关 |

ack 语义：`accepted` / `rejected` / `stale`（baseRevision 过期）/ `duplicate` /
`noop` / `failed`。`stale` 表示队列在决策时已变化——服务端稍后会补发
`state.updated`，客户端等帧即可（或重试一次，见 zemote）。

可选门控：快照 `availability: { queueEdit, sendQueuedNow, setFollowupMode,
… }`（`{allowed, reasonCode?}`），用来禁用对应按钮。zemote 没做，先不做也行。

---

## 3. 关键前提：队列状态从哪来（双通道）

### 3.1 事件推送（主通道，必须打通）

队列随会话 wire frame 到达：订阅 `subscribeConversationV4` 后，
`onDynamicConversationFrame` 推送 snapshot（含 `queue`）与 deltas（含
`state.updated → patch.queue`）。**zemote 全量依赖这条路**（`lib/protocol/
conversation.dart` 只读 snapshot + state.updated，没有任何轮询兜底），实测稳定。
zcoder 已打通（2026-08-17 修复后真机验证：`topic wire frame complete` +
`wire frame delivered` 持续到达，会话 deltas 实时流入）。

### 3.2 本仓库已知问题：07 号审计说事件推送收不到 —— 根因定论（2026-08-17）

[07-flutter-app-audit.md](07-flutter-app-audit.md) 曾记录「204 wire frames 对终端
连接永远不触发」，且与 zemote 的实测矛盾（同协议、同 `clientKind: mobileApp`、
同 `appVersion 3.6.5`）。排查结论如下，**旧的订阅参数 A/B 假设已被推翻**：

> **根因（已修复并验证）**：`RpcChannel.requestEvent` 把事件监听参数包成
> `[args]` 列表（沿用了 `requestPromise` 的「参数展开」约定，但事件**不展开**）。
> host 用 `workspacePath` 从列表上取值得到 undefined，把监听器注册到
> `conversation\0undefined` 键下，帧按真实 workspaceKey 路由永远到不了手机——
> 订阅/轮询/行数据全部正常，唯独帧收不到。修复 = `requestEvent` 直接传 args
> （对齐 zemote `addEventListener(arg: scope)` 与官方 renderer
> `onDynamicConversationFrame(n)` 传 map 本身）。
>
> 排查过程的两个误区：① 桌面日志**没有 eventFire 行 ≠ 没推帧**（桌面 rpc 日志
> 只有 call/listen/register 三类）；② 反编译桌面 asar 得出「host 用连接自身身份、
> 请求参数无关」的方向也不对——订阅参数差异虽被排除为主因，仍已顺手对齐。

下表为当时的差异记录（保留作参考；订阅参数已按 zemote 最小集对齐）：

| 参数 | zemote（可收到帧） | zcoder（已对齐） |
|------|--------------------|--------------------|
| `workspacePath` | ✅ | ✅ |
| `workspaceIdentity` | ✅（有则传） | ✅（已透传） |
| `runtimePolicy` | ❌ 不传（仅 sessions-index 传 `existing-only`） | ✅ 已去掉 |
| `connectionId` | ❌ 不传（只用于附件上传） | ✅ 已去掉 |
| `visibility` | ❌ 不传 | ❌ 也不传（`foreground` 时省略该键） |
| `sessionId` | ✅ | ✅ |

落地时的订阅形状：conversation 的 subscribe/监听/resync/unsubscribe 一律用
最小集 `{workspacePath, workspaceIdentity?, sessionId}`（`topic_session.dart` 的
`_conversationScope`）；sessions-index/workspace-config 订阅保留
`runtimePolicy: 'existing-only'`（zemote 同），监听参数同样走最小集。

### 3.3 轮询兜底（保底，但只作辅助）

`conversationRowsRangeV4` 的响应在某些 host build 会把快照字段内联进来（本仓库
`pollLatest` 已读 `control` / `meta` / `pendingInteractions`，`queue` 内联与否
未实测）。事件推送已打通后，队列以推送帧为准（`state.updated` 完整反映服务端
状态），轮询结果仅在推送缺失时补充；两者读的是同一个服务端状态，冲突时以最新
`toSeq` 为准。

---

## 4. 数据层改造

文件：`app/lib/src/protocol/topics/topic_models.dart`（快照模型）、
`app/lib/src/session/conversation_controller.dart`（状态机）。

### 4.1 `ConversationSnapshot` 增加 `queue` 字段

`topic_models.dart` 的 `ConversationSnapshot`（当前 672–754 行）加字段与解析：

```dart
final Map<String, Object?>? queue;   // {items:[{queueItemId,text,…}], autoDrain}

// fromJson 里：
queue: json['queue'] is Map<String, Object?>
    ? json['queue'] as Map<String, Object?>
    : null,
```

队列项除 `queueItemId` / `text` 外可能有 `createdAt`、`attachments`、
`inputProperties` 等——**原样透传**，客户端只读 `queueItemId` 和 `text`。

### 4.2 `ConversationState` 加队列字段与 getter

`conversation_controller.dart` 的 `ConversationState`（当前 17–161 行）：

```dart
Map<String, Object?>? queue;

List<Map<String, Object?>> get queueItems {
  final items = queue?['items'];
  if (items is! List) return const [];
  return items.whereType<Map<String, Object?>>().toList();
}

bool get autoDrain => queue?['autoDrain'] != false;

/// inputRouting.mode；缺省 startNow（与 web 客户端一致）。
String get inputRoutingMode =>
    (inputRouting?['mode']?.toString()) ?? 'startNow';
```

`applySnapshot` 里加一行：`queue = snapshot.queue;`（当前 88–104 行）。

### 4.3 修正 `state.updated` 的应用位置（关键）

现在 `applyDelta` 的 `state.updated` 走 `_applyControlPatch`，把 patch **所有键
塞进 `control`**（150–160 行）——`patch.queue` 会被错误地塞进 `control['queue']`。
`patch` 是快照顶层字段的局部更新，应按字段分发：

```dart
case 'state.updated':
  final patch = op['patch'];
  if (patch is Map<String, Object?>) _applyStatePatch(patch);
```

```dart
void _applyStatePatch(Map<String, Object?> patch) {
  patch.forEach((k, v) {
    switch (k) {
      case 'control':
        // 局部 control 对象：深合并（保留现有 phase/canStop/…）
        if (v is Map<String, Object?>) {
          control = {...control, ...v};
        }
        break;
      case 'queue':
        queue = v is Map<String, Object?> ? v : null;
        break;
      case 'inputRouting':
        inputRouting = v is Map<String, Object?> ? v : null;
        break;
      case 'meta':
        meta = v is Map<String, Object?> ? v : null;
        break;
      case 'config':
        config = v is Map<String, Object?> ? v : null;
        break;
      case 'availability':
        availability = v is Map<String, Object?> ? v : null;
        break;
    }
  });
}
```

（替换原 `_applyControlPatch`，或让后者只处理 `control` 键并新加分发。）

### 4.4 轮询兜底：`pollLatest` 读内联 `queue`

`conversation_controller.dart` 的 `pollLatest`（396–458 行）在解析
`result['control']` 等内联字段处，加：

```dart
final queue = result['queue'];
if (queue is Map<String, Object?>) state.queue = queue;
```

### 4.5 乐观更新方法

命令被服务端 `accepted` 后、确认帧（`state.updated`）到达前，UI 先本地生效。
纯状态变更放 `ConversationState`：

```dart
void removeQueueItem(String queueItemId) {
  final q = queue;
  if (q == null) return;
  final items = (q['items'] as List?)
      ?.where((i) =>
          i is Map<String, Object?> && '${i['queueItemId']}' != queueItemId)
      .toList();
  queue = {...q, 'items': items ?? const []};
}

void updateQueueItemText(String queueItemId, String newText) {
  final q = queue;
  if (q == null || q['items'] is! List) return;
  final items = [
    for (final i in q['items'] as List)
      if (i is Map<String, Object?> && '${i['queueItemId']}' == queueItemId)
        {...i, 'text': newText}
      else
        i,
  ];
  queue = {...q, 'items': items};
}

void setAutoDrainOptimistic(bool next) {
  final q = queue;
  if (q == null) return;
  queue = {...q, 'autoDrain': next};
}
```

`ConversationController` 加带 `_emit()` 的包装（UI 只调 controller，与现有
「controller 负责 notify」的分工一致）：

```dart
void optimisticRemoveQueueItem(String queueItemId) {
  final state = _state;
  if (state == null) return;
  state.removeQueueItem(queueItemId);
  _emit();
}
// 同理：optimisticUpdateQueueItemText / optimisticSetAutoDrain
```

---

## 5. 命令层改造

文件：`app/lib/src/app_controller.dart`。`_sendCommand`（301–322 行）已自动附
`baseRevision`/`baseLogEpoch`（快照有效时），队列命令直接走它即可。

### 5.1 `sendText` / `sendGoalCommand` 加队列参数

当前 `sendText`（324–332 行）：

```dart
Future<Map<String, Object?>> sendText(
  String text, {
  String? sessionId,
  List<Map<String, Object?>>? attachments,
  String? heldQueueDisposition,
  List<String>? expectedHeldQueueItemIds,
}) => _sendCommand('sendText', {
  'text': text,
  if (attachments != null && attachments.isNotEmpty)
    'attachments': attachments,
  if (heldQueueDisposition != null)
    'heldQueueDisposition': heldQueueDisposition,
  if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
    'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
}, sessionId: sessionId);
```

`sendGoalCommand`（334–335 行）同样加 `heldQueueDisposition` /
`expectedHeldQueueItemIds`。

### 5.2 队列管理命令 helpers

紧挨 `setFollowupMode`（358–360 行）加：

```dart
Future<Map<String, Object?>> sendQueuedNow(String queueItemId) =>
    _sendCommand('sendQueuedNow', {'queueItemId': queueItemId});

Future<Map<String, Object?>> editQueueItem(
        String queueItemId, String newText) =>
    _sendCommand('editQueueItem',
        {'queueItemId': queueItemId, 'newText': newText});

Future<Map<String, Object?>> deleteQueueItem(String queueItemId) =>
    _sendCommand('deleteQueueItem', {'queueItemId': queueItemId});

Future<Map<String, Object?>> reorderQueueItem(
        String queueItemId, String beforeQueueItemId) =>
    _sendCommand('reorderQueueItem', {
      'queueItemId': queueItemId,
      'beforeQueueItemId': beforeQueueItemId,
    });

Future<Map<String, Object?>> setAutoDrain(bool autoDrain) =>
    _sendCommand('setAutoDrain', {'autoDrain': autoDrain});
```

关于 `stale`：当前 `_sendCommand` 不重试。队列命令收到 `stale` 时不用管——服务端
随后推送的 `state.updated` 会把队列纠正回来；如果在意延迟，可参照 zemote
（`conversation.dart` 174–188 行）用 `revisionAtDecision` 重试一次。

---

## 6. UI 层改造

文件：`app/lib/src/ui/conversation_page.dart`（页面）、`model_config_sheet.dart`
（followup 切换，可选）。

### 6.1 发送流程：`choice` 时询问用户

`_send()`（131–159 行）在 `_sending = true` 之前插入：

```dart
final state = _state;
String? heldDisposition;
if (state != null &&
    state.inputRoutingMode == 'choice' &&
    state.queueItems.isNotEmpty) {
  heldDisposition = await _askHeldQueueDisposition();
  if (heldDisposition == null) return; // 用户取消
}
```

然后把 `heldDisposition` 透传给 `widget.app.sendText(...,
heldQueueDisposition: heldDisposition)`。

对话框（可参考 zemote `chat_page.dart` 433–453 行）：

```dart
Future<String?> _askHeldQueueDisposition() {
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('有排队中的消息'),
      content: const Text('立即发送将清空排队消息并插队执行'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
          child: const Text('排队发送'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
          child: const Text('立即发送'),
        ),
      ],
    ),
  );
}
```

另外：`sendText` 返回的 ack 若是 `rejected`（如 `inputRouting.mode == 'reject'`），
当前 `_send()` 只清输入框不提示——建议 toast `reasonCode`（`_ackRejected` /
`_ackReason` 可照抄 zemote `chat_page.dart` 394–404 行）。

### 6.2 排队消息栏（核心 UI）

页面 body 是 `Column: [Expanded(列表), _buildEntriesRow, _buildInputBar]`
（327–394 行）。在 `_buildEntriesRow(state)` 之后、`_buildInputBar()` 之前插入
`_QueueBar(state: state, app: widget.app)`。因为页面在每次 `app` notify 时整体
重建（300 行 `ListenableBuilder`），队列变化会自动反映，无需额外监听。

队列栏实现（单文件新 Widget，风格对齐 zemote `chat_page.dart` 1997–2180 行）：

```dart
class _QueueBar extends StatelessWidget {
  final ConversationState state;
  final AppController app;

  const _QueueBar({required this.state, required this.app});

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_outlined, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text('排队消息 ${items.length}', style: TextStyle(
                  fontSize: 12, color: scheme.primary)),
              const Spacer(),
              // autoDrain 开关（乐观更新 + 命令）
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  app.conversation?.optimisticSetAutoDrain(next);
                  app.setAutoDrain(next);
                },
                child: Text(state.autoDrain ? '自动发送: 开' : '自动发送: 关',
                    style: TextStyle(fontSize: 11,
                        color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text('${item['text'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                  _QueueAction(
                    icon: Icons.play_arrow,
                    tooltip: '立即发送',
                    onTap: () {
                      final id = '${item['queueItemId']}';
                      app.conversation?.optimisticRemoveQueueItem(id);
                      app.sendQueuedNow(id);
                    },
                  ),
                  _QueueAction(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onTap: () => _edit(context, item),
                  ),
                  _QueueAction(
                    icon: Icons.close,
                    tooltip: '删除',
                    onTap: () async {
                      final id = '${item['queueItemId']}';
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除排队消息？'),
                          content: Text('${item['text'] ?? ''}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                          actions: [
                            TextButton(
                                onPressed: () =>
                                    Navigator.pop(context, false),
                                child: const Text('取消')),
                            FilledButton(
                                onPressed: () =>
                                    Navigator.pop(context, true),
                                child: const Text('删除')),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      app.conversation?.optimisticRemoveQueueItem(id);
                      app.deleteQueueItem(id);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, Map<String, Object?> item) async {
    final controller =
        TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑排队消息'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    final id = '${item['queueItemId']}';
    app.conversation?.optimisticUpdateQueueItemText(id, text);
    app.editQueueItem(id, text);
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({required this.icon, required this.tooltip,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}
```

说明：

- `app.conversation?.optimistic…` 走 4.5 的 controller 包装，立即 `_emit()`；
- 命令成功后服务端 `state.updated` 帧纠正/确认；
- 乐观更新失败（命令被拒）不回滚——下一条 `state.updated` 会把队列纠正回服务端
  真实状态（与 zemote 一致）；追求更稳可加 ack 失败回滚，属可选增强；
- **排序（reorderQueueItem）**：协议和命令 helper 都有，UI 是可选加分项——在
  `_QueueAction` 加一对上移/下移按钮即可（`beforeQueueItemId` 取目标位置前一
  项的 id；移到最前时 `beforeQueueItemId` 传空串，需实测语义）。

### 6.3 followup 模式切换（排队 / 引导）

命令 `setFollowupMode` 已有 helper（`app_controller.dart` 358–360 行），缺 UI。
当前值在快照 `config.followupMode`（缺省 `queue`）。照 `ModelConfigSheet` 现有的
协作模式三件套（`modeOptions` / `currentMode` / `onModeChanged`，widget 定义在
`model_config_sheet.dart` 27–31 行）加一组可选参数：

```dart
// ModelConfigSheet 新参数（与 modeOptions 平行）
final List<String> followupOptions;       // const ['queue', 'guide']
final String? currentFollowup;            // 打开 sheet 时从会话 state 传入
final Future<void> Function(String mode)? onFollowupChanged;
```

sheet 内紧跟 `_modeChips`（284–337 行）再渲染一排 chips（`queue` → 「排队」、
`guide` → 「引导」），`onSelected` 调 `widget.onFollowupChanged`。

调用侧 `conversation_page.dart` 的 `_showModelConfigSheet`（636–708 行）接线，与
`onModeChanged`（680–690 行）同理：

```dart
followupOptions: const ['queue', 'guide'],
currentFollowup: state.config?['followupMode']?.toString() ?? 'queue',
onFollowupChanged: (mode) async {
  // 乐观更新：state.config['followupMode'] = mode（走 4.5 的 controller 包装）
  // 命令：await widget.app.setFollowupMode(mode);
},
```

注意 `locked`（agent 运行中禁改）：`setFollowupMode` 与协作模式同级，运行中是否
允许以服务端 ack 为准，可先不并入 `locked` 逻辑。

---

## 7. 测试计划

### 单元测试（`app/test/`）

- `ConversationSnapshot.fromJson`：含 `queue` 字段的快照解析（items 透传、
  autoDrain 缺省）。
- `ConversationState.applyDelta`：`state.updated {patch:{queue}}` 落到
  `state.queue` 而不是 `control`（回归 4.3 的修复）；`inputRoutingMode` /
  `autoDrain` getter 缺省值。
- 乐观更新：`removeQueueItem` / `updateQueueItemText` / `setAutoDrainOptimistic`
  在空队列、无匹配项时安全（参考 zemote `test/conversation_test.dart:235`）。

### 命令层测试

- `buildCommand` 包出的 envelope：queue 命令 payload 形状（`queueItemId` /
  `newText` / `beforeQueueItemId` / `autoDrain`），以及 `sendText` 带
  `heldQueueDisposition` / `expectedHeldQueueItemIds` 时 payload 正确。
- CAS：`_sendCommand` 在快照有效时附 `baseRevision`（现有 `hasSnapshotBase`
  逻辑覆盖）。

### 协议/E2E（真机 + 桌面）

1. 会话运行中发消息 → 队列栏出现该消息（事件推送或轮询任一通道验证）。
2. 立即发送 → 消息进入对话流、队列项消失。
3. 编辑 → 队列栏文本更新；删除 → 带确认、项消失。
4. autoDrain 关 → 运行中发送的消息挂住不执行；开 → 恢复自动执行。
5. `choice` 弹窗两种选择的行为（排队 vs 清空插队）。
6. 断线重连后队列状态恢复（resubscribe + 快照）。

---

## 8. 参考实现（zemote，同协议可对照）

| 内容 | zemote 文件 | 行号 |
|------|-------------|------|
| 命令 helpers（sendQueuedNow/editQueueItem/deleteQueueItem/setAutoDrain/setFollowupMode/sendText） | `lib/protocol/conversation.dart` | 306–430 |
| CAS 命令清单 + stale 重试 | `lib/protocol/conversation.dart` | 100–205 |
| 队列状态 getter（queueItems/autoDrain/inputRoutingMode） | `lib/protocol/conversation.dart` | 1485–1544 |
| `state.updated` 快照合并 + 乐观移除 | `lib/protocol/conversation.dart` | 1370–1421 |
| `_QueueBar`（队列栏 UI） | `lib/ui/chat_page.dart` | 1997–2180 |
| `choice` 弹窗（_askHeldQueueDisposition） | `lib/ui/chat_page.dart` | 292–301, 433–453 |
| followup 模式切换 UI | `lib/ui/chat_page.dart` | 2832–2855 |

> 注：zemote 的 `reorderQueueItem` 也只停在协议层（无 UI）；它没做轮询兜底，
> 队列全靠事件推送。zcoder 的事件推送已打通（2026-08-17），4.4 的轮询读内联
> `queue` 仅作兜底保留。
