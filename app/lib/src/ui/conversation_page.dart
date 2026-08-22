import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_controller.dart';
import '../session/conversation_controller.dart';
import '../protocol/services/services.dart';
import '../protocol/topics/topic_models.dart';
import 'request_sheet.dart';
import 'attachment_picker.dart';
import 'chat_composer.dart';
import 'model_config_sheet.dart';
import 'markdown_skill_badge.dart';
import 'mono_text.dart';
import 'reconnect_banner.dart';
import 'theme.dart';

/// Screen 4: one session's conversation. Rows stream in incrementally,
/// reasoning is collapsed by default, approvals appear inline, and the bottom
/// bar sends text or stops the agent.
class ConversationPage extends StatefulWidget {
  final AppController app;
  final String sessionId;

  /// Fallback AppBar title (the session's task title) — the snapshot's
  /// meta.title only arrives via event push, which the desktop never sends.
  final String? title;

  /// Archived sessions open read-only: history browsable, composer disabled.
  final bool archived;

  const ConversationPage({
    super.key,
    required this.app,
    required this.sessionId,
    this.title,
    this.archived = false,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  /// Bytes cache for in-chat attachment previews (keyed by attachment ref).
  static final Map<String, Uint8List> attachmentCache = {};

  final _scrollController = ScrollController();
  bool _atBottom = true;

  /// Row id of the newest row already rendered — drives the smart-scroll
  /// follow (task: auto-scroll only while the user is at the bottom).
  int? _lastNewestRowId;

  /// Row ids that have already run (or are ineligible for) the entrance
  /// animation. Lives at the page level so the one-shot "new message
  /// arrives" effect survives row-element rebuilds while scrolling.
  final Set<int> _enteredRowIds = <int>{};

  /// Whether the row log has been seeded as the animation baseline. The
  /// initial snapshot renders without entrance effects; only rows streamed
  /// in after this page attached animate in.
  bool _rowBaselineSeeded = false;

  ConversationState? _state;

  /// 会话是否已有可展示的计划（ExitPlanMode）——「计划」菜单项只在该会话
  /// 确实存在计划时出现。conversationPlansV4 是权威来源（计划 sheet 展示
  /// 同一份数据），打开会话后预取一次；已加载行中的 ExitPlanMode 工具调用
  /// 兜底覆盖预取之后新出现的计划。
  bool _hasPlans = false;
  bool _plansFetched = false;

  bool get _sessionHasPlans {
    if (_hasPlans) return true;
    final state = _state;
    if (state == null) return false;
    return state.orderedRows.any(
      (r) => r is ToolCallRow && r.toolName == 'ExitPlanMode',
    );
  }

  // Pending attachments: uploaded descriptors `{ref, fileName, mime, bytes}`
  // shown as chips above the composer and sent along with the next text.
  final _attachments = <Map<String, Object?>>[];
  bool _uploading = false;
  double _uploadProgress = 0;
  String _uploadingName = '';

  /// Uploads that failed (or hit a broken connection) keep their bytes so the
  /// file isn't lost — the chip offers retry / remove.
  final _failedUploads = <_FailedUpload>[];

  @override
  void initState() {
    super.initState();
    // Keep the screen on while driving the agent — long sessions die on
    // autolock otherwise (released in dispose).
    WakelockPlus.enable();
    _scrollController.addListener(_onScroll);
    widget.app.addListener(_onAppTick);
    _open();
  }

  /// App-level tick: keep the per-category request notifiers (which feed an
  /// open RequestSheet) in sync outside the build phase.
  void _onAppTick() {
    final state = widget.app.conversation?.state;
    if (state != null) {
      _syncRequestNotifiers(state);
      if (!_plansFetched) _ensurePlansFetched();
    }
  }

  Future<void> _open() async {
    await widget.app.openSession(widget.sessionId);
    if (!mounted) return;
    // Give the UI a beat to attach its ListenableBuilder listener first:
    // openSession already notifies, so render whatever state we have.
  }

  void _onScroll() {
    // The list is reversed: pixels == 0 is the visual bottom (latest rows),
    // and older rows load when approaching the visual top (maxScrollExtent).
    final position = _scrollController.position;
    final atBottom = position.pixels <= 120;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
    if (position.pixels > position.maxScrollExtent - 200) {
      _maybeLoadOlder();
    }
  }

  Timer? _olderDebounce;

  /// 上行拉取更早记录进行中——列表顶部显示加载动画，避免用户翻不到底时
  /// 误以为「往上拉就拉不动了」。
  bool _loadingOlder = false;

  /// 已拉到最早一条记录（loadOlderRows 返回 hasMore=false 后置位）——顶部
  /// 显示到头标记，提示没有更早的消息了。
  bool _olderEndReached = false;

  bool get _showOlderHeader => _loadingOlder || _olderEndReached;

  void _maybeLoadOlder() {
    final state = _state;
    if (state == null || !state.needsOlderRows || _loadingOlder) return;
    _olderDebounce ??= Timer(const Duration(milliseconds: 400), () async {
      _olderDebounce = null;
      await _loadOlderRows();
    });
  }

  Future<void> _loadOlderRows() async {
    if (_loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      await widget.app.conversation?.loadOlderRows();
    } finally {
      if (mounted) {
        setState(() {
          _loadingOlder = false;
          if (!(_state?.needsOlderRows ?? false)) _olderEndReached = true;
        });
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _olderDebounce?.cancel();
    widget.app.removeListener(_onAppTick);
    _scrollController.dispose();
    _approvalsNotifier.dispose();
    _questionsNotifier.dispose();
    widget.app.closeConversation();
    super.dispose();
  }

  /// ChatComposer onSend: returns true when the text was accepted (the
  /// composer then clears itself); on failure the draft stays.
  Future<bool> _sendText(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty && _attachments.isEmpty) return false;
    // inputRouting.mode == 'choice' means the user picks: keep the queue and
    // append this message, or clear the queue and jump it in. Only asked when
    // the queue is non-empty (matches the web client & zemote, doc 08 §2.2).
    final state = _state;
    String? heldDisposition;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return false; // user cancelled
    }
    try {
      // The desktop may be mid-restart (runtime respawns after relay
      // reconnect); a timeout keeps the send button from staying disabled.
      final result = await widget.app
          .sendText(
            text,
            attachments: _attachments.isEmpty
                ? null
                : List<Map<String, Object?>>.from(_attachments),
            heldQueueDisposition: heldDisposition,
          )
          .timeout(const Duration(seconds: 15));
      // A rejected ack (e.g. inputRouting.mode == 'reject') carries a
      // reasonCode — surface it instead of silently clearing the input.
      if (result['status'] == 'rejected' && mounted) {
        final reason = result['reasonCode']?.toString() ?? '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reason.isEmpty ? '消息被拒绝发送' : '消息被拒绝发送：$reason'),
          ),
        );
      }
      _attachments.clear();
      setState(() {});
      _backToBottom();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
      return false;
    }
  }

  /// Choice-mode dialog: queue the new message or clear the queue and send
  /// it immediately (doc 08 §6.1).
  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('有排队中的消息'),
        content: const Text('立即发送将清空排队消息并插队执行'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop('keepQueueAndSend'),
            child: const Text('排队发送'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop('clearQueueAndSend'),
            child: const Text('立即发送'),
          ),
        ],
      ),
    );
  }

  Future<void> _stop() async {
    await widget.app.stop();
  }

  /// User-initiated return to the bottom: re-engages the auto-follow even if
  /// the user had scrolled up (the scroll listener also re-engages it when the
  /// animation lands at the bottom).
  void _backToBottom() {
    setState(() => _atBottom = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Instant glue to the latest row, used by the auto-follow so streaming
  /// updates don't queue up animations.
  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
  }

  /// The turn currently running, if any. Turn headers arrive *before* the
  /// user message row, so rendering the status inline would place it above
  /// the new message; it is pinned to the visual bottom of the list instead.
  TurnHeaderRow? _runningTurn(List<ConversationRow> rows) {
    for (final row in rows.reversed) {
      if (row is TurnHeaderRow) {
        return row.state == 'running' ? row : null;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: widget.app,
          builder: (context, _) {
            final state = widget.app.conversation?.state;
            final phase = state?.phase ?? '';
            final title = state?.meta?['title']?.toString();
            final fallback = widget.title;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (title == null || title.isEmpty)
                      ? ((fallback == null || fallback.isEmpty)
                            ? '会话'
                            : fallback)
                      : title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (phase == 'error' && state?.lastErrorMessage != null)
                  Text(
                    state!.lastErrorMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    phase.isEmpty
                        ? (state == null ? '连接中…' : '已连接')
                        : SessionPhase.zh(phase),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                ),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Token 使用详情',
            onPressed: _showTokenUsageSheet,
            icon: const Icon(Icons.data_usage),
          ),
          PopupMenuButton<String>(
            tooltip: '会话菜单',
            onSelected: (value) {
              switch (value) {
                case 'stop':
                  _stop();
                case 'model':
                  _showModelConfigSheet();
                case 'pauseGoal':
                  _runGoalCommand(widget.app.pauseGoal, '已暂停目标');
                case 'resumeGoal':
                  _runGoalCommand(widget.app.resumeGoal, '已恢复目标');
                case 'plans':
                  _showPlansSheet();
                case 'subagents':
                  _showSubagentsSheet();
              }
            },
            itemBuilder: (context) {
              final running = _state?.isAgentRunning ?? false;
              return [
                // 打断是回合级操作（运行中允许），且只在 agent 实际运行时
                // 出现：readSession 的 session.status（2s 轮询）是权威来源，
                // control.canStop 只随事件推送快照到达并参与判断。
                if (running)
                  PopupMenuItem(
                    value: 'stop',
                    child: ListTile(
                      leading: const Icon(Icons.stop),
                      title: const Text('打断'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuItem(
                  value: 'model',
                  child: ListTile(
                    leading: Icon(Icons.tune),
                    title: Text('切换模型'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                // 目标命令按当前目标状态决定出现与否（与桌面端一致，依据
                // 会话快照 availability.pauseGoal/resumeGoal.allowed）：
                // 有目标在跑 → 仅「暂停目标」；目标已暂停 → 仅「恢复目标」；
                // 无目标（或 availability 未到达）→ 两者都不出现。
                if (_state?.canPauseGoal ?? false)
                  const PopupMenuItem(
                    value: 'pauseGoal',
                    child: ListTile(
                      leading: Icon(Icons.pause_circle_outline),
                      title: Text('暂停目标'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (_state?.canResumeGoal ?? false)
                  const PopupMenuItem(
                    value: 'resumeGoal',
                    child: ListTile(
                      leading: Icon(Icons.play_circle_outline),
                      title: Text('恢复目标'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                // 计划仅在会话存在可展示的计划（conversationPlansV4 中有
                // ExitPlanMode 记录，或已加载行里出现 ExitPlanMode 工具
                // 调用）时出现，避免空计划页入口。
                if (_sessionHasPlans)
                  const PopupMenuItem(
                    value: 'plans',
                    child: ListTile(
                      leading: Icon(Icons.assignment_outlined),
                      title: Text('计划'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                // 仅在当前确有运行中的子代理时出现（快照 subagents.running[]）。
                if (_state?.runningSubagents.isNotEmpty ?? false)
                  const PopupMenuItem(
                    value: 'subagents',
                    child: ListTile(
                      leading: Icon(Icons.hub_outlined),
                      title: Text('运行中的子代理'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ];
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.app,
        builder: (context, _) {
          final conversation = widget.app.conversation;
          final state = conversation?.state;
          _state = state;
          if (state == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = state.orderedRows;
          // The turn-header row's state stays "running" in the persisted log
          // after the turn ends (the desktop's own web UI gates on session
          // phase, not the row) — so the status line is shown only while
          // readSession says the session is running.
          final runningTurn = state.isAgentRunning ? _runningTurn(rows) : null;
          // Smart scroll: while the user sits at the bottom, keep the latest
          // row visible as new rows stream in. Scrolling up disengages the
          // follow (see _onScroll); the floating button or scrolling back to
          // the bottom re-engages it.
          final newestRowId = rows.isEmpty ? null : rows.last.rowId;
          // First snapshot is the animation baseline: history rows render
          // without entrance effects, so only rows streamed in while this
          // page is open fade-and-rise into view.
          if (!_rowBaselineSeeded) {
            _rowBaselineSeeded = true;
            _enteredRowIds.addAll(rows.map((r) => r.rowId));
          }
          int? entranceRowId;
          if (newestRowId != _lastNewestRowId) {
            if (newestRowId != null &&
                !_enteredRowIds.contains(newestRowId)) {
              entranceRowId = newestRowId;
            }
            _lastNewestRowId = newestRowId;
            _enteredRowIds.addAll(rows.map((r) => r.rowId));
            if (_atBottom && newestRowId != null) _jumpToBottom();
          }
          // 子代理在会话流里占两行（Task 工具行 + subagent 摘要行，doc 05 两
          // 者都会发射）：渲染时跳过摘要行，只留工具行（输入/输出/错误详情、
          // 运行状态都在其上）——折叠配对见 foldedSubagentRowIds；配对失败
          // （parentToolCallId 缺失或配对行在加载窗口外）回退为两行都显示。
          final foldedSubagent = foldedSubagentRowIds(rows);
          final renderRows = [
            for (final r in rows)
              if (!foldedSubagent.contains(r.rowId)) r,
          ];
          final extraStatusRow = runningTurn != null ? 1 : 0;
          _maybeAutoShowInteraction(state);
          final todos = _latestTodos(state);
          return Column(
            children: [
              ReconnectBanner(app: widget.app),
              Expanded(
                child: Stack(
                  children: [
                    renderRows.isEmpty
                        ? const Center(child: Text('等待 agent 开始工作…'))
                        : ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                            itemCount:
                                renderRows.length +
                                extraStatusRow +
                                (_showOlderHeader ? 1 : 0),
                            itemBuilder: (context, i) {
                              // Reversed: index 0 is the visual bottom. The
                              // running-turn status line pins there, below the
                              // newest message; real rows shift up by one.
                              // The oldest side (visual top) hosts the
                              // older-rows loading / end-of-history header.
                              if (_showOlderHeader &&
                                  i == renderRows.length + extraStatusRow) {
                                return OlderRowsHeader(
                                  key: const ValueKey('older-rows-header'),
                                  loading: _loadingOlder,
                                  reachedEnd: _olderEndReached,
                                );
                              }
                              if (runningTurn != null && i == 0) {
                                return _TurnStatusLine(
                                  key: ValueKey('turn-${runningTurn.rowId}'),
                                  startedAt:
                                      runningTurn.startedAt ??
                                      runningTurn.createdAt,
                                );
                              }
                              final j = renderRows.length - 1 - (i - extraStatusRow);
                              return _rowWidget(
                                context,
                                renderRows[j],
                                nextCreatedAt: j + 1 < renderRows.length
                                    ? renderRows[j + 1].createdAt
                                    : null,
                                entranceRowId: entranceRowId,
                              );
                            },
                          ),
                    if (todos != null && todos.isNotEmpty)
                      Positioned(
                        right: 14,
                        // Rests at the bottom edge; moves up to sit above the
                        // back-to-bottom button when that one is visible.
                        bottom: _atBottom ? 14 : 14 + 40 + 10,
                        child: _TodoFab(
                          todos: todos,
                          onTap: () => _showTodoSheet(todos),
                        ),
                      ),
                    if (!_atBottom)
                      Positioned(
                        right: 14,
                        bottom: 14,
                        child: FloatingActionButton.small(
                          heroTag: 'back-to-bottom',
                          tooltip: '回到底部',
                          onPressed: _backToBottom,
                          child: const Icon(Icons.keyboard_arrow_down),
                        ),
                      ),
                  ],
                ),
              ),
              _buildEntriesRow(state),
              _QueueBar(state: state, app: widget.app),
              _buildInputBar(),
            ],
          );
        },
      ),
    );
  }

  // ---------- Entries row above the input bar (todos / approvals / questions) ----------

  /// Latest todo list, by source priority (matches how the web client gets
  /// its todo panel):
  /// 1. snapshot `plan` (`{items: [{id, content, status}]}`, via frames) —
  ///    authoritative, present even when the agent cleared the list;
  /// 2. readSession `todos`/`todoGroups` (the 2s poll the web client uses);
  /// 3. the latest TodoWrite tool-call row (last resort, may be missing
  ///    after a cache reload).
  /// Status values differ per source (`inProgress` in plan, `in_progress`
  /// elsewhere) — normalized to `in_progress`.
  List<TodoItem>? _latestTodos(ConversationState state) {
    final plan = state.plan;
    if (plan != null) {
      final planItems = plan['items'];
      if (planItems is List) {
        return [
          for (final t in planItems.whereType<Map<String, Object?>>())
            TodoItem(
              content: (t['content'] ?? '').toString(),
              status: _normalizeTodoStatus(t['status']?.toString()),
            ),
        ];
      }
      return const [];
    }
    final polled = state.readSessionTodos;
    if (polled != null) {
      return [
        for (final t in polled)
          TodoItem(
            content: (t['content'] ?? '').toString(),
            status: _normalizeTodoStatus(t['status']?.toString()),
          ),
      ];
    }
    for (final row in state.orderedRows.reversed) {
      if (row is ToolCallRow && row.toolName == 'TodoWrite') {
        final input = row.input ?? ToolCallLine._tryDecode(row.inputText);
        final todos = input?['todos'];
        if (todos is List) {
          final items = <TodoItem>[];
          for (final t in todos.whereType<Map>()) {
            final status = _normalizeTodoStatus(t['status']?.toString());
            final content = (t['activeForm'] ?? t['content'])?.toString() ?? '';
            items.add(TodoItem(content: content, status: status));
          }
          return items;
        }
        // TodoWrite with no parsed todos — treat as the current empty state.
        return const [];
      }
    }
    return null;
  }

  /// Snapshot `plan` uses camelCase `inProgress`; readSession/TodoWrite rows
  /// use snake_case `in_progress` — normalize to the sheet's expected value.
  static String _normalizeTodoStatus(String? status) {
    if (status == null || status.isEmpty) return 'pending';
    if (status == 'inProgress') return 'in_progress';
    return status;
  }

  Widget _buildEntriesRow(ConversationState state) {
    final requests = state.pendingRequests;
    final approvals = requests.where((r) => !r.isElicitation).toList();
    final questions = requests.where((r) => r.isElicitation).toList();
    final entries = <Widget>[];
    // Todos live in the floating checklist button above the input area now.
    if (approvals.isNotEmpty) {
      entries.add(
        _EntryChip(
          tooltip: '审批 · ${approvals.length}',
          icon: Icons.verified_user_outlined,
          count: approvals.length,
          onTap: () => _showRequestSheet(approvals),
        ),
      );
    }
    if (questions.isNotEmpty) {
      entries.add(
        _EntryChip(
          tooltip: '提问 · ${questions.length}',
          icon: Icons.quiz_outlined,
          count: questions.length,
          onTap: () => _showRequestSheet(questions),
        ),
      );
    }
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(children: entries),
    );
  }

  /// Auto-pops the approval/question sheet once when the detail page opens and
  /// a pending request exists (web client shows a modal for the first pending
  /// interaction; here it is a bottom sheet). Dismissal is left to the sheet
  /// (back / outside tap); the entry chips above the input re-open it.
  bool _autoShownInteraction = false;

  void _maybeAutoShowInteraction(ConversationState state) {
    if (_autoShownInteraction || state.pendingRequests.isEmpty) return;
    _autoShownInteraction = true;
    final requests = state.pendingRequests;
    final first = requests.first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showRequestSheet(
        first.isElicitation
            ? requests.where((r) => r.isElicitation).toList()
            : requests.where((r) => !r.isElicitation).toList(),
      );
    });
  }

  Future<void> _showTodoSheet(List<TodoItem> todos) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _TodoSheet(todos: todos),
    );
  }

  /// 预取一次计划历史用于「计划」菜单项的条件显示；失败静默（由
  /// ExitPlanMode 行扫描兜底，不阻塞页面）。
  Future<void> _ensurePlansFetched() async {
    if (_plansFetched) return;
    _plansFetched = true;
    try {
      final plans = await widget.app.fetchPlans().timeout(
        const Duration(seconds: 15),
      );
      if (!mounted) return;
      final raw = plans['plans'];
      final list = raw is List
          ? raw.whereType<Map<String, Object?>>()
          : const <Map<String, Object?>>[];
      setState(() {
        _hasPlans = list.any((row) {
          final status = row['status']?.toString();
          return row['toolName']?.toString() == 'ExitPlanMode' &&
              (status == 'success' ||
                  status == 'error' ||
                  status == 'cancelled');
        });
      });
    } catch (_) {
      // 预取失败不报错：有 ExitPlanMode 行时「计划」菜单项仍会出现。
    }
  }

  /// Fetches the session's plan history (`conversationPlansV4` — the
  /// ExitPlanMode tool-call rows) and shows them in a sheet.
  Future<void> _showPlansSheet() async {
    try {
      final plans = await widget.app.fetchPlans().timeout(
        const Duration(seconds: 15),
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => _PlansSheet(plans: plans),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取计划失败：$e')));
      }
    }
  }

  /// Running sub-agent list. Selecting one stacks the execution-detail sheet
  /// on top WITHOUT closing this sheet (its route stays mounted below), so
  /// the user can inspect several sub-agents and then just dismiss back.
  Future<void> _showSubagentsSheet() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      enableDrag: false,
      builder: (sheetContext) => _SubagentsSheet(
        app: widget.app,
        onOpen: _showSubagentDetail,
      ),
    );
  }

  /// The execution process of one running sub-agent: its child session's own
  /// conversation log, rendered with the same row widgets as the main page
  /// ("和主代理一样"). Stacked above the sub-agent list sheet.
  Future<void> _showSubagentDetail(Map<String, Object?> entry) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _SubagentDetailSheet(
        app: widget.app,
        entry: entry,
        childSessionId: entry['childSessionId']?.toString(),
      ),
    );
  }

  Future<void> _showRequestSheet(List<PendingRequest> requests) {
    // A modal bottom sheet (isScrollControlled) so the panel rides up with the
    // IME instead of being covered by the keyboard. Horizontal swipes between
    // question pages are unaffected; the sheet itself is dismissed via back /
    // outside tap (enableDrag: false keeps vertical scrolls inside pages).
    //
    // The sheet follows the live pending list: resolved elsewhere (timeout or
    // another client) removes pages in place, new arrivals append, and the
    // sheet auto-closes when nothing is left.
    final category = requests.first.isElicitation;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      enableDrag: false,
      builder: (sheetContext) => Padding(
        // Push the panel above the IME (canonical bottom-sheet pattern).
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: RequestSheet(
          requests: requests,
          onResolve: _requestResolverFor,
          requestsListenable: category
              ? _questionsNotifier
              : _approvalsNotifier,
        ),
      ),
    );
  }

  /// Live per-category pending lists feeding an open RequestSheet.
  final _approvalsNotifier = ValueNotifier<List<PendingRequest>>(const []);
  final _questionsNotifier = ValueNotifier<List<PendingRequest>>(const []);

  void _syncRequestNotifiers(ConversationState state) {
    final approvals = state.pendingRequests
        .where((r) => !r.isElicitation)
        .toList();
    final questions = state.pendingRequests
        .where((r) => r.isElicitation)
        .toList();
    if (!_sameIds(_approvalsNotifier.value, approvals)) {
      _approvalsNotifier.value = approvals;
    }
    if (!_sameIds(_questionsNotifier.value, questions)) {
      _questionsNotifier.value = questions;
    }
  }

  static bool _sameIds(List<PendingRequest> a, List<PendingRequest> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].requestId != b[i].requestId) return false;
    }
    return true;
  }

  /// Resolving throws on failure — the sheet keeps the user's answers and
  /// surfaces the error inline, so nothing typed is lost to a flaky network.
  Future<void> Function(PendingRequest request, Map<String, Object?> answer)
  get _requestResolverFor =>
      (request, answer) => widget.app.resolveRequest(
        request.requestId,
        optionId: answer['optionId']?.toString(),
        action: answer['action']?.toString(),
        content: answer['content'],
      );

  // ---------- Token usage detail sheet ----------

  Future<void> _showTokenUsageSheet() {
    final state = _state;
    if (state == null) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _TokenUsageSheet(
        usage: state.contextUsage,
        liveUsage: state.usage,
        tokenUsage: state.tokenUsage,
      ),
    );
  }

  // ---------- Model / thought-level switch sheet ----------

  /// Runs a goal command (pause/resume) with a success snackbar; the desktop
  /// rejects the command with a clear error when no goal is active.
  Future<void> _runGoalCommand(
    Future<Map<String, Object?>> Function() command,
    String successText,
  ) async {
    try {
      await command().timeout(const Duration(seconds: 15));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successText)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('目标操作失败：$e')));
      }
    }
  }

  Future<void> _showModelConfigSheet() async {
    final state = _state;
    if (state == null) return;
    // The workspace registry (same source as the sessions page picker) — a
    // session's own readSession settings only carry the models it resolves
    // to (one provider, or a bare provider UUID once completed).
    final config = await widget.app.conversationPickerConfig();
    if (!mounted) return;
    if (config.availableModels.isEmpty &&
        config.availableThoughtLevels.isEmpty) {
      return;
    }
    // Collaboration-mode options prefer prepareWorkspace's configOptions;
    // fall back to the desktop's canonical sets. The current mode comes from
    // the session's readSession settings (`settings.mode.current`), which is
    // more accurate than the workspace-level prepareWorkspace value.
    final prep = await widget.app.fetchWorkspacePrep();
    final modeOptions = _prepOptionValues(
      prep,
      const ['mode', 'collaborationMode'],
      const ['build', 'edit', 'plan', 'yolo'],
    );
    final currentMode =
        config.mode ??
        _prepCurrentValue(prep, const ['mode', 'collaborationMode']);
    if (!mounted) return;
    // Session-level rewrites are refused while the agent runs: the sheet
    // opens for browsing but every selection is locked.
    final running = state.isAgentRunning;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      enableDrag: false,
      // Same interaction as the sessions page's picker: selections apply
      // immediately but the sheet stays open until 完成 (autoClose: false).
      builder: (sheetContext) => ModelConfigSheet(
        config: config,
        autoClose: false,
        subtitle: '选择后立即应用于当前会话',
        locked: running,
        lockedReason: running ? 'agent 运行中，先中断再切换' : null,
        modeOptions: modeOptions,
        currentMode: currentMode,
        onModeChanged: (mode) async {
          try {
            await widget.app.switchCollaborationMode(mode);
          } catch (e) {
            if (sheetContext.mounted) {
              ScaffoldMessenger.of(
                sheetContext,
              ).showSnackBar(SnackBar(content: Text('切换模式失败：$e')));
            }
          }
        },
        onApply: (provider, model, thoughtLevel) async {
          try {
            await widget.app.switchModel(
              provider,
              model,
              thoughtLevel: thoughtLevel,
            );
          } catch (e) {
            if (sheetContext.mounted) {
              ScaffoldMessenger.of(
                sheetContext,
              ).showSnackBar(SnackBar(content: Text('切换模型失败：$e')));
            }
          }
        },
      ),
    );
  }

  /// Config-option values by id from `prepareWorkspace`, else [fallback].
  List<String> _prepOptionValues(
    WorkspacePrep? prep,
    List<String> ids,
    List<String> fallback,
  ) {
    if (prep != null) {
      for (final id in ids) {
        final option = prep.option(id);
        if (option != null && option.options.isNotEmpty) {
          return option.options.map((o) => o.value).toList();
        }
      }
    }
    return fallback;
  }

  /// The option's current value (workspace-level mode/followup), if any.
  String? _prepCurrentValue(WorkspacePrep? prep, List<String> ids) {
    if (prep == null) return null;
    for (final id in ids) {
      final option = prep.option(id);
      if (option != null) {
        final v = option.currentValue;
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return null;
  }

  // ---------- Input bar ----------

  // ---------- Attachments ----------

  Future<void> _pickAttachment() async {
    final PickedAttachment? picked;
    try {
      picked = await showAttachmentPicker(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择附件失败：$e')));
      }
      return;
    }
    if (picked == null || !mounted) return;
    await _uploadAttachment(
      name: picked.name,
      mime: picked.mime,
      bytes: picked.bytes,
    );
  }

  Future<void> _uploadAttachment({
    required String name,
    required String mime,
    required Uint8List bytes,
    _FailedUpload? retryOf,
  }) async {
    // The page's own session id — reading it from the conversation state
    // would silently drop uploads fired before the first snapshot arrives.
    final sessionId = widget.sessionId;
    setState(() {
      if (retryOf != null) _failedUploads.remove(retryOf);
      _uploading = true;
      _uploadingName = name;
      _uploadProgress = 0;
    });
    try {
      final descriptor = await widget.app.uploadAttachment(
        sessionId,
        fileName: name,
        mime: mime,
        bytes: bytes,
        onProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _attachments.add(descriptor);
        _uploading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _failedUploads.add(
            _FailedUpload(name: name, mime: mime, bytes: bytes),
          );
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('上传失败：$e（可从暂存条重试）')));
      }
    }
  }

  /// Pending-attachment chips + in-flight upload progress, shown above the
  /// composer while anything is staged.
  Widget? _buildAttachmentBar() {
    if (_attachments.isEmpty && !_uploading && _failedUploads.isEmpty) {
      return null;
    }
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final a in _attachments)
          InputChip(
            label: Text(a['fileName']?.toString() ?? '附件'),
            avatar: (a['mime']?.toString().startsWith('image/') ?? false)
                ? const Icon(Icons.image_outlined, size: 18)
                : const Icon(Icons.insert_drive_file_outlined, size: 18),
            onDeleted: () => setState(() => _attachments.remove(a)),
          ),
        // Failed uploads stay as retryable chips — the picked file must never
        // vanish silently.
        for (final f in _failedUploads)
          InputChip(
            label: Text(f.name),
            avatar: Icon(Icons.error_outline, size: 18, color: scheme.error),
            labelStyle: TextStyle(color: scheme.error),
            side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
            onPressed: _uploading
                ? null
                : () => _uploadAttachment(
                    name: f.name,
                    mime: f.mime,
                    bytes: f.bytes,
                    retryOf: f,
                  ),
            onDeleted: () => setState(() => _failedUploads.remove(f)),
          ),
        if (_uploading)
          SizedBox(
            width: 220,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _uploadingName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LinearProgressIndicator(value: _uploadProgress),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildInputBar() {
    // Archived sessions are read-only: history browsable, composer replaced
    // by a banner (restore from the session list to continue).
    if (widget.archived) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Row(
            children: [
              Icon(
                Icons.archive_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已归档的会话为只读，恢复后可继续',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ChatComposer(
      app: widget.app,
      hintText: '给 agent 发消息…',
      busy: _uploading,
      onPickAttachment: _pickAttachment,
      header: _buildAttachmentBar(),
      onSend: _sendText,
    );
  }

  // ---------- Row renderers ----------

  Widget _rowWidget(
    BuildContext context,
    ConversationRow row, {
    int? nextCreatedAt,
    int? entranceRowId,
  }) {
    final Widget child;
    switch (row) {
      case UserInputRow():
        child = _LongPressRow(
          onLongPress: () => _showRowActions(row),
          child: _UserBubble(row: row, app: widget.app),
        );
      case AssistantTextRow():
        if (row.text.trim().isEmpty) return const SizedBox.shrink();
        child = Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _LongPressRow(
            onLongPress: () => _showRowActions(row),
            child: _MarkdownText(
              text: row.text,
              color: RowColors.assistant(context),
            ),
          ),
        );
      case ReasoningRow():
        // Thinking duration ≈ time until the next row appeared.
        int? durationMs;
        final started = row.createdAt;
        if (started != null && nextCreatedAt != null) {
          final d = nextCreatedAt - started;
          if (d >= 1000 && d < 30 * 60 * 1000) durationMs = d;
        }
        child = _ReasoningLine(
          durationMs: durationMs,
          onTap: row.text.isEmpty
              ? null
              : () => _showReasoningDetail(row, durationMs),
        );
      case ToolCallRow():
        child = ToolCallLine(row: row, onTap: () => _showToolDetail(row));
      case SubagentRow():
        child = _SubagentLine(row: row);
      case TimelineMarkerRow():
        child = _TimelineMarkerLine(row: row);
      case TurnHeaderRow():
        // Rendered separately, pinned to the visual bottom (_runningTurn).
        return const SizedBox.shrink();
      default:
        return const SizedBox.shrink();
    }
    // The newest row streamed in while the page is open plays a one-shot
    // fade-and-rise. The wrapper is applied unconditionally (same key) so the
    // animation state survives streaming rebuilds; a row that is scrolled out
    // and rebuilt sees entranceRowId null and the effect does not replay.
    //
    // RepaintBoundary keeps a dirty row (or the animated status line) from
    // repainting its neighbors — markdown-heavy messages repaint in isolation.
    return RepaintBoundary(
      child: _RowEntrance(
        key: ValueKey('entrance-${row.rowId}'),
        animate: entranceRowId != null && row.rowId == entranceRowId,
        child: child,
      ),
    );
  }

  // ---------- Row long-press actions (retry / edit) ----------

  /// The newest user-sent message in the current log. Only it supports
  /// edit-and-resend; older user rows long-press as a no-op.
  UserInputRow? get _lastUserInputRow {
    final rows = _state?.orderedRows;
    if (rows == null) return null;
    for (final row in rows.reversed) {
      if (row is UserInputRow) return row;
    }
    return null;
  }

  /// Long-press on a user or assistant row offers row-target commands.
  Future<void> _showRowActions(ConversationRow row) async {
    final canEditResend =
        row is UserInputRow && row.rowId == _lastUserInputRow?.rowId;
    final List<Widget> actions = [
      if (canEditResend)
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('编辑重发'),
          subtitle: Text(
            row.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            Navigator.of(context).pop();
            _editUserQuery(row);
          },
        ),
    ];
    if (actions.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: actions),
      ),
    );
  }

  Map<String, Object?> _rowTarget(ConversationRow row) => {
    'rowId': row.rowId,
    if (row.entityId != null) 'entityId': row.entityId,
  };

  Future<void> _editUserQuery(UserInputRow row) async {
    final controller = TextEditingController(text: row.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑重发'),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '修改后的指令'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('重发'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newText == null || newText.trim().isEmpty) return;
    try {
      await widget.app
          .editUserQuery(_rowTarget(row), newText)
          .timeout(const Duration(seconds: 15));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已重新发送')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重发失败：$e')));
      }
    }
  }

  // ---------- Detail dialogs (tap-to-expand opens a modal, not inline) ----------

  void _showReasoningDetail(ReasoningRow row, int? durationMs) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _DetailDialog(
        title: durationMs == null
            ? '思考过程'
            : '思考过程 · 持续了 ${_formatDuration(durationMs)}',
        child: SelectableText(
          row.text,
          style: Theme.of(
            dialogContext,
          ).textTheme.bodySmall?.copyWith(height: 1.5),
        ),
      ),
    );
  }

  void _showToolDetail(ToolCallRow row) {
    final (_, verb, _) = ToolCallLine._describe(row);
    final input = ToolCallLine._prettyInput(row);
    final output = row.output;
    // For tools without a status verb mapping, _describe falls back to the
    // tool name itself; printing both would read "AskUserQuestion AskUserQuestion".
    final title = verb == row.toolName ? row.toolName : '$verb ${row.toolName}';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _DetailDialog(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (input.isNotEmpty) ...[
              const DetailLabel('输入'),
              MonoText(text: ToolCallLine._trim(input)),
            ],
            if (output != null && output.isNotEmpty) ...[
              const DetailLabel('输出'),
              MonoText(text: ToolCallLine._trim(output)),
            ],
            if (row.error != null && row.error!.isNotEmpty) ...[
              const DetailLabel('错误'),
              Text(
                row.error!,
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.error,
                  fontSize: 12.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------- Shared bits ----------

/// Formats a millisecond duration the way the desktop does:
/// "11 秒", "12 分 11 秒", "1 小时 3 分".
String _formatDuration(int ms) {
  final totalSeconds = ms ~/ 1000;
  if (totalSeconds < 60) return '$totalSeconds 秒';
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes < 60) return '$minutes 分 $seconds 秒';
  final hours = minutes ~/ 60;
  return '$hours 小时 ${minutes % 60} 分';
}

String _firstLine(String s, [int max = 90]) {
  final line = s.split('\n').first.trim();
  return line.length > max ? '${line.substring(0, max)}…' : line;
}

/// A sub-agent registry entry's `status` (missing → empty).
String _entryStatus(Map<String, Object?> entry) =>
    entry['status']?.toString() ?? '';

/// Small leading icon for a one-line row, colored by status. Running rows no
/// longer reach this — they lead with the [SweepingLabel] instead; only
/// completed/failed rows get an icon.
Widget _statusIcon(BuildContext context, String status, IconData icon) {
  final scheme = Theme.of(context).colorScheme;
  final failed = status == 'error' || status == 'failed';
  return Icon(
    failed ? Icons.error_outline : icon,
    size: 15,
    color: failed ? scheme.error : scheme.onSurfaceVariant,
  );
}

// ---------- Row widgets ----------

/// Wraps a conversation row so a long-press opens the row action menu.
/// Implemented with a [Listener] timer instead of `GestureDetector.onLongPress`
/// — the latter loses the gesture arena to the row's `SelectableText` text
/// selection (long-press then only selects text and the menu never opens).
/// Taps still reach the child untouched.
/// A picked file whose upload failed; kept so the user can retry or drop it.
class _FailedUpload {
  final String name;
  final String mime;
  final Uint8List bytes;
  const _FailedUpload({
    required this.name,
    required this.mime,
    required this.bytes,
  });
}

class _LongPressRow extends StatefulWidget {
  final VoidCallback onLongPress;
  final Widget child;
  const _LongPressRow({required this.onLongPress, required this.child});

  @override
  State<_LongPressRow> createState() => _LongPressRowState();
}

class _LongPressRowState extends State<_LongPressRow> {
  Timer? _timer;

  void _onPointerDown(PointerDownEvent event) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), widget.onLongPress);
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: (_) => _cancel(),
      onPointerCancel: (_) => _cancel(),
      behavior: HitTestBehavior.opaque,
      child: widget.child,
    );
  }
}

/// Shared markdown style sheet: assistant text (light/dark aware) and the
/// user bubble (which additionally registers the skill badge rule).
MarkdownStyleSheet _markdownSheet(BuildContext context, Color textColor) {
  final scheme = Theme.of(context).colorScheme;
  final theme = Theme.of(context);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium?.copyWith(color: textColor, height: 1.55),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      color: scheme.onSurface,
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    codeblockPadding: const EdgeInsets.all(10),
    codeblockDecoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
    listIndent: 20,
  );
}

/// A markdown body whose built widget instance is cached per element.
///
/// `MarkdownBody(data:)` re-parses the text on every `build`. The conversation
/// page's whole body rebuilds on each state emit (the 2s polls notify even
/// when nothing changed), so an unchanged long message would otherwise be
/// re-parsed and re-laid-out several times a second — the source of scroll
/// jank in markdown-heavy sessions. Returning the same `MarkdownBody` instance
/// lets Flutter's `identical` short-circuit in `Element.updateChild` skip the
/// child rebuild entirely; it is only invalidated when the text, color, or
/// theme actually changes.
class _MarkdownText extends StatefulWidget {
  final String text;
  final Color color;
  const _MarkdownText({required this.text, required this.color});

  @override
  State<_MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<_MarkdownText> {
  MarkdownBody? _cached;
  ThemeData? _cachedTheme;

  @override
  void didUpdateWidget(_MarkdownText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.color != widget.color) {
      _cached = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cached = _cached;
    if (cached == null || !identical(_cachedTheme, theme)) {
      _cachedTheme = theme;
      _cached = MarkdownBody(
        data: widget.text,
        selectable: true,
        styleSheet: _markdownSheet(context, widget.color),
      );
    }
    return _cached!;
  }
}

class _UserBubble extends StatelessWidget {
  final UserInputRow row;
  final AppController app;
  const _UserBubble({required this.row, required this.app});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = row.text;
    final attachments = row.attachments;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Container(
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (attachments.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in attachments)
                      _AttachmentThumb(attachment: a, app: app),
                  ],
                ),
                if (text.isNotEmpty) const SizedBox(height: 6),
              ],
              if (text.isNotEmpty)
                (hasSkillInvoke(text) || hasSlashInvoke(text))
                    ? MarkdownBody(
                        data: text,
                        selectable: true,
                        styleSheet: _markdownSheet(
                          context,
                          scheme.onPrimaryContainer,
                        ),
                        extensionSet: chatBadgeExtensionSet,
                        builders: {
                          'skillBadge': SkillBadgeBuilder(),
                          'slashBadge': SlashBadgeBuilder(),
                        },
                      )
                    : SelectableText(
                        text,
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          height: 1.4,
                        ),
                      ),
            ],
          ),
        ),
      ),
    );
  }
}

/// In-chat attachment badge: a small tag (icon + file name) that opens a
/// full-size preview dialog on tap (images load via `attachmentReadV4` with
/// a page-level bytes cache).
class _AttachmentThumb extends StatefulWidget {
  final RowAttachment attachment;
  final AppController app;
  const _AttachmentThumb({required this.attachment, required this.app});

  @override
  State<_AttachmentThumb> createState() => _AttachmentThumbState();
}

class _AttachmentThumbState extends State<_AttachmentThumb> {
  Uint8List? _bytes;
  bool _loading = false;

  Future<Uint8List?> _load() async {
    if (_bytes != null) return _bytes;
    if (_loading) return null;
    _loading = true;
    try {
      final cache = _ConversationPageState.attachmentCache;
      final ref = widget.attachment.previewRef ?? widget.attachment.ref;
      final cached = cache[ref];
      if (cached != null) {
        _bytes = cached;
        return cached;
      }
      final bytes = await widget.app.readAttachment(ref);
      if (bytes != null) cache[ref] = bytes;
      if (mounted) setState(() => _bytes = bytes);
      return bytes;
    } finally {
      // Reset so a failed read can be retried on the next tap.
      _loading = false;
    }
  }

  Future<void> _showPreview() async {
    final a = widget.attachment;
    if (!a.isImage) {
      // Non-image: simple info dialog.
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(a.fileName),
          content: Text('类型：${a.mime}\n大小：${_formatBytes(a.bytes)}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    // Image: load (with cache) then show a zoomable preview dialog.
    final bytes = await _load();
    if (!mounted || bytes == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 8,
              child: Text(
                a.fileName,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = widget.attachment;
    final icon = a.isImage
        ? Icons.image_outlined
        : Icons.insert_drive_file_outlined;
    return InkWell(
      onTap: _showPreview,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                a.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-of-list (oldest side) history-loading header. While the older-rows RPC
/// is in flight a spinner plus hint fills the silent gap (otherwise pulling to
/// the top feels like the list is stuck); once the earliest record is reached
/// it switches to an end-of-history marker. Public so it can be widget-tested
/// independently of the full conversation page.
class OlderRowsHeader extends StatelessWidget {
  final bool loading;
  final bool reachedEnd;

  const OlderRowsHeader({
    super.key,
    required this.loading,
    required this.reachedEnd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: loading
            ? Row(
                key: const ValueKey('older-loading'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('正在加载更早记录…', style: style),
                ],
              )
            : reachedEnd
                ? Text(
                    '已加载全部历史记录',
                    key: const ValueKey('older-end'),
                    style: style,
                  )
                : const SizedBox.shrink(key: ValueKey('older-idle')),
      ),
    );
  }
}

/// Desktop-style running-turn status. A fluorescent highlight sweeps across
/// bold "工作中" like a glowing stick passing over the line, always left to
/// right ("工" → "中"), then restarts from the left. It is drawn as a single
/// continuous gradient (gray → pure white → gray) masked onto the text, so the
/// light edge passes straight through each glyph — every character brightens
/// from the inside and both ends of the label fade — like a moving highlight
/// over an image of the text. The elapsed time stays right-aligned and static.
/// Ticks once a second — the row stream alone only refreshes on poll/delta
/// events.
///
/// Uses a ShaderMask (animated LinearGradient) for the continuous in-glyph
/// gradient.
// Sweep-label palette (shared by the bottom "工作中" line and sub-agent
// status): passing light flares the swept glyphs up to pure white while the
// rest of the label rests in a mid gray — maximum text-vs-light contrast.
const Color _sweepTextGray = Color(0xFF8B9199);
const Color _sweepFluorescent = Color(0xFFFFFFFF);

/// Status word lit by a travelling highlight ("工作中", "正在执行") — the
/// light band sweeps left→right and its reset happens off screen, so the
/// animation never looks like a jump. Public so it can be widget-tested
/// independently of the full conversation page. ShaderMask compositing is
/// unreliable on the Android emulator (whole label renders solid grey, no
/// logcat error); verify on a real device.
class SweepingLabel extends StatefulWidget {
  final String text;
  const SweepingLabel({super.key, required this.text});

  @override
  State<SweepingLabel> createState() => _SweepingLabelState();
}

class _SweepingLabelState extends State<SweepingLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep;

  // Light ramp half-width and off-screen margin, both as fractions of the
  // total masked width. The margin lets the band slide in from beyond the left
  // edge and roll out past the right edge, so the sweep's reset happens off
  // screen and never looks like a jump. Only the right margin occupies layout
  // width — the left margin is virtual (shader space only), so the first
  // glyph's left edge sits exactly at the widget's left edge and the label
  // left-aligns with row icons and other sweep labels.
  static const double _bandHalf = 0.15;
  static const double _padFraction = 0.8;

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  /// [text] lit by a continuous gradient light. [sweep]∈[0..1] maps the light
  /// from off beyond the left edge (band fully outside the glyphs) to off
  /// beyond the right edge, so the band slides in and rolls out naturally and
  /// its reset happens off screen. The gray→white→gray ramp passes straight
  /// through every glyph as it travels.
  Widget _fluorescentLabel(BuildContext context, double sweep) {
    final base = (Theme.of(context).textTheme.labelMedium ??
            const TextStyle(fontSize: 12))
        .copyWith(color: _sweepTextGray, fontWeight: FontWeight.w800);
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: base),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = _padFraction * tp.width;
    // Map the sweep so the band ends up outside the masked area at both ends.
    final c = _bandHalf + sweep * (1 - 2 * _bandHalf);
    return ShaderMask(
      // The layout holds only the right margin; the gradient rect is extended
      // `pad` beyond the left edge, so the slide-in still happens off-glyph
      // and the sweep math is unchanged from the symmetric-margin version.
      shaderCallback: (bounds) => LinearGradient(
        colors: [
          _sweepTextGray,
          _sweepTextGray,
          _sweepFluorescent,
          _sweepFluorescent,
          _sweepTextGray,
          _sweepTextGray,
        ],
        stops: [
          0,
          c - _bandHalf,
          c - _bandHalf * 0.4,
          c + _bandHalf * 0.4,
          c + _bandHalf,
          1,
        ],
      ).createShader(Rect.fromLTWH(
        bounds.left - pad,
        bounds.top,
        bounds.width + pad,
        bounds.height,
      )),
      blendMode: BlendMode.srcATop,
      child: Padding(
        padding: EdgeInsets.only(right: pad),
        child: Text(widget.text, style: base),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sweep,
      builder: (_, _) {
        // Sweep 0→1 travels the light from off the left edge to off the
        // right; the curve eases the slide in/out.
        final sweep = Curves.easeInOutSine.transform(_sweep.value);
        return _fluorescentLabel(context, sweep);
      },
    );
  }
}

/// Pinned bottom status line while a turn is running: the "工作中" sweep on
/// the left, elapsed time on the right (time is static per build — only the
/// label sweeps; the 1s timer re-renders the elapsed text).
class _TurnStatusLine extends StatefulWidget {
  final int? startedAt;
  const _TurnStatusLine({super.key, required this.startedAt});

  @override
  State<_TurnStatusLine> createState() => _TurnStatusLineState();
}

class _TurnStatusLineState extends State<_TurnStatusLine> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    final elapsed = startedAt == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - startedAt;
    final labelStyle = (Theme.of(context).textTheme.labelMedium ??
            const TextStyle(fontSize: 12))
        .copyWith(color: _sweepTextGray, fontWeight: FontWeight.w800);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SweepingLabel(text: '工作中'),
          if (elapsed != null && elapsed >= 0)
            Text(_formatDuration(elapsed), style: labelStyle),
        ],
      ),
    );
  }
}

/// Desktop-style thinking line: "思考过程 持续了 11 秒". Tapping opens the full
/// reasoning text in a dialog (inline expansion made the list jump).
class _ReasoningLine extends StatelessWidget {
  final int? durationMs;
  final VoidCallback? onTap;
  const _ReasoningLine({required this.durationMs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                durationMs == null
                    ? '思考过程'
                    : '思考过程 持续了 ${_formatDuration(durationMs!)}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact one-line tool call, matching the desktop: an icon, a status verb
/// and a preview ("已执行 grep -ao …", "MCP Kimi Cu · Get App State"). Tapping
/// opens input/output in a dialog (inline expansion made the list jump).
/// Public so it can be widget-tested independently of the full conversation
/// page.
class ToolCallLine extends StatelessWidget {
  final ToolCallRow row;
  final VoidCallback onTap;

  const ToolCallLine({super.key, required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, verb, preview) = _describe(row);
    // 运行中行首一律用「正在执行」扫光（与底部「工作中」同一动画，左缘对齐），
    // 不再转圈；点开仍可看输入/输出/错误。
    final running = row.status == 'running' || row.status == 'pending';
    // 扫光词已是状态表达：Task 的「子代理」与 Bash/未知工具的状态动词
    // （「正在执行」「正在运行」）不再重复；工具名动词（读取/编辑/MCP xx 等）
    // 保留，运行中也能看出是什么工具在执行。
    final verbShown = !running ||
        (row.toolName != 'Task' && verb != '正在执行' && verb != '正在运行');

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            running
                ? const SweepingLabel(text: '正在执行')
                : _statusIcon(context, row.status, icon),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    if (verbShown)
                      TextSpan(
                        text: verb,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    if (preview.isNotEmpty)
                      TextSpan(
                        text: verbShown ? ' $preview' : preview,
                        style: TextStyle(color: scheme.onSurface),
                      ),
                  ],
                ),
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _trim(String s) =>
      s.length > 4000 ? '${s.substring(0, 4000)}\n…（已截断）' : s;

  static String _prettyInput(ToolCallRow row) {
    final input = row.input;
    if (input != null) {
      try {
        return const JsonEncoder.withIndent('  ').convert(input);
      } catch (_) {
        return input.toString();
      }
    }
    final raw = row.inputText ?? '';
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  /// Maps a tool call to (icon, status verb, preview text) the way the
  /// desktop's compact rows read.
  static (IconData, String, String) _describe(ToolCallRow row) {
    final name = row.toolName;
    final input = row.input ?? _tryDecode(row.inputText);
    String? arg(String key) {
      final v = input?[key];
      return v == null ? null : _firstLine(v.toString());
    }

    final running = row.status == 'running' || row.status == 'pending';
    final failed = row.status == 'error' || row.status == 'failed';

    switch (name) {
      case 'Bash':
        final verb = running
            ? '正在执行'
            : failed
            ? '执行失败'
            : '已执行';
        return (
          Icons.terminal,
          verb,
          arg('command') ?? _extractJsonString(row.inputText, 'command') ?? '',
        );
      case 'Read':
        return (
          Icons.description_outlined,
          '读取',
          arg('file_path') ??
              _extractJsonString(row.inputText, 'file_path') ??
              '',
        );
      case 'Edit':
        return (
          Icons.edit_outlined,
          '编辑',
          arg('file_path') ??
              _extractJsonString(row.inputText, 'file_path') ??
              '',
        );
      case 'Write':
        return (
          Icons.note_add_outlined,
          '写入',
          arg('file_path') ??
              _extractJsonString(row.inputText, 'file_path') ??
              '',
        );
      case 'Grep':
        return (Icons.search, '搜索', arg('pattern') ?? '');
      case 'Glob':
        return (Icons.find_in_page_outlined, '查找文件', arg('pattern') ?? '');
      case 'TodoWrite':
        return (Icons.checklist, '待办', _todoSummary(input));
      case 'Task':
        return (Icons.smart_toy_outlined, '子代理', arg('description') ?? '');
      case 'WebFetch':
        return (Icons.public, '获取网页', arg('url') ?? '');
      case 'WebSearch':
        return (Icons.travel_explore, '联网搜索', arg('query') ?? '');
      default:
        if (name.startsWith('mcp__')) {
          final parts = name.split('__');
          if (parts.length >= 3) {
            return (
              Icons.extension_outlined,
              'MCP ${_humanize(parts[1])}',
              '· ${_humanize(parts.sublist(2).join('_'))}',
            );
          }
        }
        final verb = running
            ? '正在运行'
            : failed
            ? '运行失败'
            : name;
        final preview = input == null
            ? ''
            : input.entries
                  .where((e) => e.value is String || e.value is num)
                  .map((e) => e.value.toString())
                  .firstOrNull;
        return (Icons.build_outlined, verb, _firstLine(preview ?? ''));
    }
  }

  static Map<String, Object?>? _tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Extracts a string field from possibly-truncated JSON (streaming input).
  static String? _extractJsonString(String? raw, String key) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)').firstMatch(raw);
    return m?.group(1);
  }

  static String _todoSummary(Map<String, Object?>? input) {
    final todos = input?['todos'];
    if (todos is! List) return '';
    final items = todos.whereType<Map>().toList();
    if (items.isEmpty) return '';
    final done = items.where((t) => t['status'] == 'completed').length;
    final active = items.firstWhere(
      (t) => t['status'] != 'completed',
      orElse: () => items.last,
    );
    final content =
        (active['activeForm'] ?? active['content'])?.toString() ?? '';
    return '${_firstLine(content, 40)} $done/${items.length}';
  }

  /// "kimi-cu" → "Kimi cu", "get_app_state" → "Get app state" (desktop style:
  /// first word capitalized, the rest lowercase).
  static String _humanize(String slug) {
    final words = slug.split(RegExp(r'[-_]')).where((w) => w.isNotEmpty);
    return words
        .mapIndexed(
          (i, w) => i == 0 ? '${w[0].toUpperCase()}${w.substring(1)}' : w,
        )
        .join(' ');
  }
}

extension _IndexedMap<E> on Iterable<E> {
  Iterable<T> mapIndexed<T>(T Function(int index, E e) f) {
    var i = 0;
    return map((e) => f(i++, e));
  }
}

/// One-line subagent row: "探索 · …" style, with a status icon.
class _SubagentLine extends StatelessWidget {
  final SubagentRow row;
  const _SubagentLine({required this.row});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final summary = row.summaryText.isEmpty
        ? '子代理'
        : _firstLine(row.summaryText);
    // 未与 Task 工具行配对折叠的独立子代理行：运行中同样以「正在执行」
    // 扫光替代转圈指示（与主行的折叠态一致）。
    final running = row.status == 'running' || row.status == 'pending';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          running
              ? const SweepingLabel(text: '正在执行')
              : _statusIcon(context, row.status, Icons.smart_toy_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Running sub-agent list sheet. Stays mounted while a sub-agent's
/// execution-detail sheet is stacked on top, so switching between sub-agents
/// never rebuilds or re-fetches the list.
class _SubagentsSheet extends StatelessWidget {
  final AppController app;
  final void Function(Map<String, Object?> entry) onOpen;
  const _SubagentsSheet({required this.app, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final entries = app.conversation?.state?.runningSubagents ??
              const <Map<String, Object?>>[];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.hub_outlined, size: 20, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      '运行中的子代理',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    '当前没有运行中的子代理',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final entry = entries[i];
                      return _SubagentTile(
                        entry: entry,
                        onTap: () => onOpen(entry),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One running sub-agent in the list sheet.
class _SubagentTile extends StatelessWidget {
  final Map<String, Object?> entry;
  final VoidCallback onTap;
  const _SubagentTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = entry['title']?.toString() ?? '';
    final type = entry['subagentType']?.toString() ?? '';
    final summary = entry['summary']?.toString() ?? '';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      // 弹层语义本身即「运行中」：leading 用固定图标，不转圈也不扫光。
      leading: Icon(
        Icons.smart_toy_outlined,
        size: 15,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(
        title.isEmpty ? '未命名子代理' : title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: (summary.isEmpty && type.isEmpty)
          ? null
          : Text(
              [if (type.isNotEmpty) type, if (summary.isNotEmpty) summary]
                  .join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}

/// One running sub-agent's execution process: its child session's own
/// conversation log, rendered with the same row widgets as the main page.
/// Polls the child session's latest rows (same RPC as the main page's tail
/// poll); the header status follows the snapshot's subagents registry live.
class _SubagentDetailSheet extends StatefulWidget {
  final AppController app;
  final Map<String, Object?> entry;
  final String? childSessionId;
  const _SubagentDetailSheet({
    required this.app,
    required this.entry,
    this.childSessionId,
  });

  @override
  State<_SubagentDetailSheet> createState() => _SubagentDetailSheetState();
}

class _SubagentDetailSheetState extends State<_SubagentDetailSheet> {
  final SplayTreeMap<int, ConversationRow> _rows = SplayTreeMap();
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    final childId = widget.childSessionId;
    if (childId == null || childId.isEmpty) {
      _loading = false;
      _error = '该子代理没有可查看的会话';
      return;
    }
    _fetch();
    // Mirror the main page's 2s tail-poll cadence for the child session.
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _fetch());
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final channel = widget.app.conversation?.bridge.topicSession;
    final childId = widget.childSessionId;
    if (channel == null || childId == null || childId.isEmpty) return;
    try {
      final result = await channel.rowsRange(childId, limit: 60);
      final rowsJson = result['rows'];
      if (rowsJson is! List) return;
      if (_disposed || !mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        for (final r in rowsJson.whereType<Map<String, Object?>>()) {
          final row = ConversationRow.fromJson(r);
          _rows[row.rowId] = row;
        }
      });
    } catch (e) {
      if (_disposed || !mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// The live registry entry for this sub-agent, if it is still running.
  Map<String, Object?>? _liveEntry() {
    final childId = widget.childSessionId;
    if (childId == null) return null;
    final running = widget.app.conversation?.state?.runningSubagents ??
        const <Map<String, Object?>>[];
    for (final e in running) {
      if (e['childSessionId']?.toString() == childId) return e;
    }
    return null;
  }

  String _statusZh(String status) => switch (status) {
    'running' => '运行中',
    'success' => '已完成',
    'error' => '出错',
    _ => status.isEmpty ? '' : status,
  };

  String _age(int? startedAt) {
    if (startedAt == null || startedAt <= 0) return '';
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(startedAt),
    );
    if (elapsed.inMinutes < 1) return '${elapsed.inSeconds}s';
    return '${elapsed.inMinutes}m';
  }

  /// Reasoning detail dialog, mirroring the main page: the collapsed
  /// "思考过程" line expands on tap to the full thinking text.
  void _showReasoningDetail(ReasoningRow row, int? durationMs) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _DetailDialog(
        title: durationMs == null
            ? '思考过程'
            : '思考过程 · 持续了 ${_formatDuration(durationMs)}',
        child: SelectableText(
          row.text,
          style: Theme.of(
            dialogContext,
          ).textTheme.bodySmall?.copyWith(height: 1.5),
        ),
      ),
    );
  }

  /// Tool input/output detail dialog (same shape as the main page).
  void _showToolDetail(ToolCallRow row) {
    final (_, verb, _) = ToolCallLine._describe(row);
    final input = ToolCallLine._prettyInput(row);
    final output = row.output;
    final title = verb == row.toolName ? row.toolName : '$verb ${row.toolName}';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _DetailDialog(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (input.isNotEmpty) ...[
              const DetailLabel('输入'),
              MonoText(text: ToolCallLine._trim(input)),
            ],
            if (output != null && output.isNotEmpty) ...[
              const DetailLabel('输出'),
              MonoText(text: ToolCallLine._trim(output)),
            ],
          ],
        ),
      ),
    );
  }

  /// Renders one child-session row with the same widgets as the main page.
  /// [nextCreatedAt] is the chronologically-next row's timestamp, used for
  /// the reasoning-duration label like the main page.
  Widget _buildRow(ConversationRow row, {int? nextCreatedAt}) {
    switch (row) {
      case UserInputRow():
        return _LongPressRow(
          onLongPress: () {},
          child: _UserBubble(row: row, app: widget.app),
        );
      case AssistantTextRow():
        if (row.text.trim().isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _LongPressRow(
            onLongPress: () {},
            child: _MarkdownText(
              text: row.text,
              color: RowColors.assistant(context),
            ),
          ),
        );
      case ReasoningRow():
        // Thinking duration ≈ time until the next row appeared (main page
        // parity).
        int? durationMs;
        final started = row.createdAt;
        if (started != null && nextCreatedAt != null) {
          final d = nextCreatedAt - started;
          if (d >= 1000 && d < 30 * 60 * 1000) durationMs = d;
        }
        return _ReasoningLine(
          durationMs: durationMs,
          onTap: row.text.isEmpty
              ? null
              : () => _showReasoningDetail(row, durationMs),
        );
      case ToolCallRow():
        return ToolCallLine(row: row, onTap: () => _showToolDetail(row));
      case SubagentRow():
        return _SubagentLine(row: row);
      case TimelineMarkerRow():
        return _TimelineMarkerLine(row: row);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    final allRows = _rows.values.toList();
    // 与主页面同一折叠：子代理的 Task 工具行保留、摘要行跳过。
    final foldedSubagent = foldedSubagentRowIds(allRows);
    final rows = [
      for (final r in allRows)
        if (!foldedSubagent.contains(r.rowId)) r,
    ];
    if (rows.isEmpty) {
      // Show the fetch error only when there is nothing to display; transient
      // poll failures while rows exist keep the log visible (the next tick
      // recovers).
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '无法加载子代理执行记录：$_error',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        );
      }
      return Center(
        child: Text(
          '暂无执行记录',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      reverse: true, // newest at the visual bottom — new rows stay in view
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        // rows is ascending; index n−1−i walks newest→oldest. The
        // chronologically-next row for rows[k] is rows[k+1], whose timestamp
        // sizes the reasoning-duration label.
        final k = rows.length - 1 - i;
        return _buildRow(
          rows[k],
          nextCreatedAt: k + 1 < rows.length ? rows[k + 1].createdAt : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: ListenableBuilder(
          listenable: widget.app,
          builder: (context, _) {
            final live = _liveEntry() ?? widget.entry;
            final title = live['title']?.toString() ?? '';
            final status = _statusZh(_entryStatus(live));
            final type = live['subagentType']?.toString() ?? '';
            final age = _age(live['startedAt'] as int?);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Row(
                    children: [
                      Icon(Icons.smart_toy_outlined, size: 20,
                          color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title.isEmpty ? '未命名子代理' : title,
                              style: Theme.of(context).textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (type.isNotEmpty || status.isNotEmpty || age.isNotEmpty)
                              Text(
                                [type, status, if (age.isNotEmpty) '已运行 $age']
                                    .where((s) => s.isNotEmpty)
                                    .join(' · '),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body(context)),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Timeline marker row — currently only context compaction markers appear
/// ("上下文已压缩 · 110491 → 15187 tokens").
class _TimelineMarkerLine extends StatelessWidget {
  final TimelineMarkerRow row;
  const _TimelineMarkerLine({required this.row});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    final IconData icon;
    if (row.markerType == 'compact') {
      icon = Icons.compress;
      final before = row.tokensBefore;
      final after = row.tokensAfter;
      text = before != null && after != null
          ? '上下文已压缩 · $before → $after tokens'
          : '上下文已压缩';
    } else if (row.markerType.isNotEmpty) {
      icon = Icons.more_horiz;
      text = row.markerType;
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: scheme.outline),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.outline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal detail view for expandable rows (thinking, tool calls). Dismisses on
/// back / outside tap (showDialog defaults), so the list never reflows.
class _DetailDialog extends StatelessWidget {
  final String title;
  final Widget child;
  const _DetailDialog({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      title: Text(title, style: Theme.of(context).textTheme.titleSmall),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(child: child),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

// ---------- Entry chips (todos / approvals / questions) ----------

/// One item of a TodoWrite tool call's `todos` array.
class TodoItem {
  final String content;
  final String status; // pending | in_progress | completed
  const TodoItem({required this.content, required this.status});
}

/// Small icon-with-count chip shown above the input bar; tapping opens the
/// matching bottom sheet. Hidden entirely when there is nothing to show.
class _EntryChip extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  const _EntryChip({
    required this.tooltip,
    required this.icon,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Badge(
        label: Text('$count'),
        child: IconButton.filledTonal(
          tooltip: tooltip,
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

/// Floating checklist button with a corner badge. Red badge shows how many
/// todos are unfinished (black label); green badge shows the total todo count
/// once every todo is completed (white label).
class _TodoFab extends StatelessWidget {
  final List<TodoItem> todos;
  final VoidCallback onTap;
  const _TodoFab({required this.todos, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final unfinished = todos.where((t) => t.status != 'completed').length;
    final allDone = unfinished == 0;
    return Badge.count(
      count: allDone ? todos.length : unfinished,
      backgroundColor:
          allDone ? Colors.green.shade600 : Colors.red.shade600,
      textColor: allDone ? Colors.white : Colors.black,
      child: FloatingActionButton.small(
        heroTag: 'todo-fab',
        tooltip: '查看待办',
        onPressed: onTap,
        child: const Icon(Icons.checklist),
      ),
    );
  }
}

// ---------- Todos bottom sheet ----------

class _TodoSheet extends StatelessWidget {
  final List<TodoItem> todos;
  const _TodoSheet({required this.todos});

  static String _statusLabel(String status) => switch (status) {
    'completed' => '已完成',
    'in_progress' => '进行中',
    'pending' => '待办',
    _ => status,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = todos.where((t) => t.status == 'completed').length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  '待办 · $done/${todos.length}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final todo in todos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            switch (todo.status) {
                              'completed' => Icons.check_circle,
                              'in_progress' => Icons.radio_button_checked,
                              _ => Icons.radio_button_unchecked,
                            },
                            size: 18,
                            color: switch (todo.status) {
                              'completed' => scheme.primary,
                              'in_progress' => scheme.tertiary,
                              _ => scheme.outline,
                            },
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              todo.content.isEmpty ? '（无内容）' : todo.content,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    decoration: todo.status == 'completed'
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: todo.status == 'completed'
                                        ? scheme.onSurfaceVariant
                                        : scheme.onSurface,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _statusLabel(todo.status),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Plans bottom sheet ----------

/// Shows the session's plan history (`conversationPlansV4`): the TodoWrite
/// tool-call rows, newest first, each with its tool status and the todos it
/// carried (raw JSON text).
class _PlansSheet extends StatelessWidget {
  final Map<String, Object?> plans;
  const _PlansSheet({required this.plans});

  /// The desktop's 计划 panel is built from the ExitPlanMode tool calls:
  /// each carries the plan markdown (`input.plan` / `text` / `content`) and
  /// an optional `planFilePath` — extracted here the same way the web client
  /// does (`input` → `inputText` JSON → `output` → raw fallbacks).
  static ({String markdown, String? planFilePath}) _extractPlan(
    Map<String, Object?> row,
  ) {
    final candidates = <Object?>[
      row['input'],
      _tryDecodeJson(row['inputText']?.toString() ?? ''),
      row['output'],
    ];
    for (final c in candidates) {
      final plan = _planFrom(c);
      if (plan != null) return plan;
    }
    return (markdown: '', planFilePath: null);
  }

  static ({String markdown, String? planFilePath})? _planFrom(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return (markdown: value.trim(), planFilePath: null);
    }
    if (value is Map) {
      Object? pick(String key) => value[key];
      final markdown = [pick('plan'), pick('text'), pick('content')]
          .whereType<String>()
          .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
      if (markdown.trim().isNotEmpty) {
        final file = value['planFilePath'];
        return (
          markdown: markdown.trim(),
          planFilePath: file is String && file.isNotEmpty ? file : null,
        );
      }
    }
    return null;
  }

  static Object? _tryDecodeJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = plans['plans'];
    final list = raw is List
        ? raw.whereType<Map<String, Object?>>().toList()
        : <Map<String, Object?>>[];
    final planItems = [
      for (final row in list)
        if (row['toolName']?.toString() == 'ExitPlanMode' &&
            (row['status']?.toString() == 'success' ||
                row['status']?.toString() == 'error' ||
                row['status']?.toString() == 'cancelled'))
          (row: row, plan: _extractPlan(row)),
    ].reversed.toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.assignment_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '计划 · ${planItems.length} 条',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: planItems.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          '暂无计划',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: planItems.length,
                      separatorBuilder: (_, _) => const Divider(height: 16),
                      itemBuilder: (context, i) {
                        final item = planItems[i];
                        final markdown = item.plan.markdown;
                        final title = _planTitle(markdown);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.assignment_outlined,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    title.isEmpty ? '计划' : title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            if (item.plan.planFilePath != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  item.plan.planFilePath!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: scheme.tertiary),
                                ),
                              ),
                            if (markdown.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: _MarkdownText(
                                  text: markdown,
                                  color: scheme.onSurface,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Title from the first `# Heading` line, else the first non-empty line
  /// (mirrors the web client's `$ct`).
  static String _planTitle(String markdown) {
    final heading = RegExp(
      r'^\s{0,3}#(?!#)\s+(.+?)\s*#*\s*$',
      multiLine: true,
    ).firstMatch(markdown);
    if (heading != null) {
      final title = heading.group(1)?.trim();
      if (title != null && title.isNotEmpty) return title;
    }
    for (final line in markdown.split(RegExp(r'\r?\n'))) {
      final trimmed = line
          .replaceFirst(RegExp(r'^\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+)'), '')
          .trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}

// ---------- Approval / question bottom sheet ----------

/// Renders a list of pending requests (one bottom sheet per category —
/// approvals vs questions are separate entries). Each request shows its
/// prompt and the option buttons; AskUserQuestion requests show the
/// per-question selector rows plus a custom answer field.
// ---------- Token usage detail sheet ----------

class _TokenUsageSheet extends StatelessWidget {
  final ContextUsage usage;

  /// Live usage pushed with conversation frames (`snapshot.usage` /
  /// `state.updated`) — `contextWindow.cache.hitRate` is what the desktop's
  /// chat header shows, so this wins over the readSession poll's `usage`.
  final ConversationUsage? liveUsage;
  final Map<String, Object?>? tokenUsage;
  const _TokenUsageSheet({
    required this.usage,
    this.liveUsage,
    this.tokenUsage,
  });

  static const _sourceLabels = <String, String>{
    'messages': '消息',
    'system_prompt': '系统提示词',
    'meta_user_context': '其他',
    'skills': '技能',
    'tool_prompt': '其他',
    'system_tool_schemas': '系统工具',
    'mcp_tool_schemas': 'MCP 工具',
  };

  static String _sourceLabel(String source) => _sourceLabels[source] ?? source;

  String _fmt(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final used = usage.used;
    final size = usage.size;
    final ratio = usage.fillRatio;
    final breakdown = usage.breakdown;
    final totalChars = breakdown.fold<int>(0, (s, e) => s + e.chars);
    final hitRate = liveUsage?.cacheHitRate ?? usage.cacheHitRate;
    final token = tokenUsage;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.data_usage, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Token 使用详情',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Context-window fill bar.
            Row(
              children: [
                Expanded(
                  child: Text(
                    size <= 0
                        ? '上下文'
                        : '上下文 ${_fmt(used)} / ${_fmt(size)}'
                              '${ratio != null ? ' (${(ratio * 100).toStringAsFixed(1)}%)' : ''}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio ?? 0,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 12),
            if (breakdown.isNotEmpty) ...[
              Text(
                '上下文构成',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (final entry in breakdown)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 84,
                        child: Text(
                          _sourceLabel(entry.source),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: totalChars <= 0
                                ? 0
                                : (entry.chars / totalChars).clamp(0.0, 1.0),
                            minHeight: 6,
                            color: scheme.tertiary,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 52,
                        child: Text(
                          totalChars <= 0
                              ? ''
                              : '${(entry.chars * 100 / totalChars).toStringAsFixed(1)}%',
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Icon(Icons.bolt, size: 16, color: scheme.tertiary),
                const SizedBox(width: 6),
                Text('平均缓存命中率', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                Text(
                  hitRate == null
                      ? '—'
                      : '${(hitRate * 100).toStringAsFixed(1)}%',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (token != null && token.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '累计输入 ${_fmt(token['inputTokens'] as int? ?? 0)} · '
                '输出 ${_fmt(token['outputTokens'] as int? ?? 0)} · '
                '缓存读取 ${_fmt(token['cacheReadTokens'] as int? ?? 0)}'
                '${token['modelRequestCount'] is int ? ' · ${token['modelRequestCount']} 次请求' : ''}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------- Held queue bar ----------

/// Queued-message panel between the message list and the input bar: shows
/// every held message with per-item actions (send now / edit / delete) and
/// the auto-drain switch (doc 08 §6.2). The page rebuilds on every app
/// notify, so queue changes from `state.updated` frames render automatically.
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
              Text(
                '排队消息 ${items.length}',
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
              const Spacer(),
              // autoDrain switch (optimistic update + command).
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  app.conversation?.optimisticSetAutoDrain(next);
                  app.setAutoDrain(next);
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    state.autoDrain ? '自动发送: 开' : '自动发送: 关',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
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
                    child: Text(
                      '${item['text'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
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
                    onTap: () => _delete(context, item),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, Map<String, Object?> item) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑排队消息'),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    final id = '${item['queueItemId']}';
    app.conversation?.optimisticUpdateQueueItemText(id, text);
    app.editQueueItem(id, text);
  }

  Future<void> _delete(BuildContext context, Map<String, Object?> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除排队消息？'),
        content: Text(
          '${item['text'] ?? ''}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = '${item['queueItemId']}';
    app.conversation?.optimisticRemoveQueueItem(id);
    app.deleteQueueItem(id);
  }
}

/// Compact icon action inside the queue bar.
class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// One-shot fade-and-rise applied to the newest row that streams in while the
/// conversation page is open. Kept as its own stateful widget so the entrance
/// does not replay when the row's element is rebuilt after scrolling: such a
/// rebuilt element is created with [animate] false and renders at full
/// opacity — only the initial "watched it arrive" build animates.
class _RowEntrance extends StatefulWidget {
  const _RowEntrance({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<_RowEntrance> createState() => _RowEntranceState();
}

class _RowEntranceState extends State<_RowEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
