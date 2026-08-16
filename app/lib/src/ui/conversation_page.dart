import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_controller.dart';
import '../session/conversation_controller.dart';
import '../session/models.dart';
import 'model_config_sheet.dart';
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
  const ConversationPage({
    super.key,
    required this.app,
    required this.sessionId,
    this.title,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  bool _sending = false;
  bool _atBottom = true;

  /// Row id of the newest row already rendered — drives the smart-scroll
  /// follow (task: auto-scroll only while the user is at the bottom).
  int? _lastNewestRowId;

  ConversationState? _state;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _open();
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

  void _maybeLoadOlder() {
    final state = _state;
    if (state == null || !state.needsOlderRows) return;
    _olderDebounce ??= Timer(const Duration(milliseconds: 400), () async {
      _olderDebounce = null;
      await widget.app.conversation?.loadOlderRows();
    });
  }

  @override
  void dispose() {
    _olderDebounce?.cancel();
    _scrollController.dispose();
    _inputController.dispose();
    widget.app.closeConversation();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      // The desktop may be mid-restart (runtime respawns after relay
      // reconnect); a timeout keeps the send button from staying disabled.
      await widget.app.sendText(text).timeout(const Duration(seconds: 15));
      _inputController.clear();
      _backToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
          IconButton(
            tooltip: '模型与思考等级',
            onPressed: _showModelConfigSheet,
            icon: const Icon(Icons.tune),
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
          final runningTurn = _runningTurn(rows);
          // Smart scroll: while the user sits at the bottom, keep the latest
          // row visible as new rows stream in. Scrolling up disengages the
          // follow (see _onScroll); the floating button or scrolling back to
          // the bottom re-engages it.
          final newestRowId = rows.isEmpty ? null : rows.last.rowId;
          if (newestRowId != _lastNewestRowId) {
            _lastNewestRowId = newestRowId;
            if (_atBottom && newestRowId != null) _jumpToBottom();
          }
          final extraStatusRow = runningTurn != null ? 1 : 0;
          _maybeAutoShowInteraction(state);
          return Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    rows.isEmpty
                        ? const Center(
                            child: Text('等待 agent 开始工作…'),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                            itemCount: rows.length + extraStatusRow,
                            itemBuilder: (context, i) {
                              // Reversed: index 0 is the visual bottom. The
                              // running-turn status line pins there, below the
                              // newest message; real rows shift up by one.
                              if (runningTurn != null && i == 0) {
                                return _TurnStatusLine(
                                  key: ValueKey('turn-${runningTurn.rowId}'),
                                  startedAt: runningTurn.startedAt ??
                                      runningTurn.createdAt,
                                );
                              }
                              final j =
                                  rows.length - 1 - (i - extraStatusRow);
                              return _rowWidget(
                                context,
                                rows[j],
                                nextCreatedAt: j + 1 < rows.length
                                    ? rows[j + 1].createdAt
                                    : null,
                              );
                            },
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
              _buildInputBar(),
            ],
          );
        },
      ),
    );
  }

  // ---------- Entries row above the input bar (todos / approvals / questions) ----------

  /// Latest TodoWrite call's todo list, parsed from the row stream (the same
  /// source the desktop's web client uses — there is no dedicated todos RPC).
  List<TodoItem>? _latestTodos(ConversationState state) {
    for (final row in state.orderedRows.reversed) {
      if (row is ToolCallRow && row.toolName == 'TodoWrite') {
        final input = row.input ?? _ToolCallLine._tryDecode(row.inputText);
        final todos = input?['todos'];
        if (todos is List) {
          final items = <TodoItem>[];
          for (final t in todos.whereType<Map>()) {
            final status = t['status']?.toString() ?? 'pending';
            final content = (t['activeForm'] ?? t['content'])?.toString() ?? '';
            items.add(TodoItem(
              content: content,
              status: status,
            ));
          }
          return items;
        }
        // TodoWrite with no parsed todos — treat as the current empty state.
        return const [];
      }
    }
    return null;
  }

  Widget _buildEntriesRow(ConversationState state) {
    final todos = _latestTodos(state);
    final requests = state.pendingRequests;
    final approvals = requests.where((r) => !r.isElicitation).toList();
    final questions = requests.where((r) => r.isElicitation).toList();
    final entries = <Widget>[];
    if (todos != null && todos.isNotEmpty) {
      entries.add(_EntryChip(
        tooltip: '查看待办',
        icon: Icons.checklist,
        count: todos.length,
        onTap: () => _showTodoSheet(todos),
      ));
    }
    if (approvals.isNotEmpty) {
      entries.add(_EntryChip(
        tooltip: '审批 · ${approvals.length}',
        icon: Icons.verified_user_outlined,
        count: approvals.length,
        onTap: () => _showRequestSheet(approvals),
      ));
    }
    if (questions.isNotEmpty) {
      entries.add(_EntryChip(
        tooltip: '提问 · ${questions.length}',
        icon: Icons.quiz_outlined,
        count: questions.length,
        onTap: () => _showRequestSheet(questions),
      ));
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

  Future<void> _showRequestSheet(List<PendingRequest> requests) {
    // A modal bottom sheet (isScrollControlled) so the panel rides up with the
    // IME instead of being covered by the keyboard. Horizontal swipes between
    // question pages are unaffected; the sheet itself is dismissed via back /
    // outside tap (enableDrag: false keeps vertical scrolls inside pages).
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
        child: _RequestSheet(
          requests: requests,
          onResolve: _requestResolverFor,
        ),
      ),
    );
  }

  Future<void> Function(PendingRequest request, Map<String, Object?> answer)
      get _requestResolverFor =>
          (request, answer) async {
            try {
              await widget.app.resolveRequest(
                request.requestId,
                optionId: answer['optionId']?.toString(),
                action: answer['action']?.toString(),
                content: answer['content'],
              );
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('提交失败：$e')),
                );
              }
            }
          };

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
        tokenUsage: state.tokenUsage,
      ),
    );
  }

  // ---------- Model / thought-level switch sheet ----------

  Future<void> _showModelConfigSheet() {
    final state = _state;
    if (state == null) return Future.value();
    final config = state.modelConfig;
    if (config.availableModels.isEmpty &&
        config.availableThoughtLevels.isEmpty) {
      return Future.value();
    }
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ModelConfigSheet(
        config: config,
        onApply: (provider, model, thoughtLevel) async {
          try {
            await widget.app.switchModel(provider, model,
                thoughtLevel: thoughtLevel);
          } catch (e) {
            if (sheetContext.mounted) {
              ScaffoldMessenger.of(sheetContext).showSnackBar(
                SnackBar(content: Text('切换模型失败：$e')),
              );
            }
          }
        },
      ),
    );
  }

  // ---------- Input bar ----------

  Widget _buildInputBar() {
    final state = _state;
    // Without event push the snapshot's control.canStop never arrives;
    // fall back to "connected" (state exists) so the user can still interrupt.
    final canStop = state == null
        ? false
        : (state.canStopOrNull ?? true);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton.filledTonal(
                tooltip: '打断',
                onPressed: canStop ? _stop : null,
                icon: const Icon(Icons.stop),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '给 agent 发消息…',
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Row renderers ----------

  Widget _rowWidget(BuildContext context, ConversationRow row,
      {int? nextCreatedAt}) {
    switch (row) {
      case UserInputRow():
        return _UserBubble(text: row.text);
      case AssistantTextRow():
        if (row.text.trim().isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _MarkdownText(
            text: row.text,
            color: RowColors.assistant(context),
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
        return _ReasoningLine(
          durationMs: durationMs,
          onTap: row.text.isEmpty
              ? null
              : () => _showReasoningDetail(row, durationMs),
        );
      case ToolCallRow():
        return _ToolCallLine(
          row: row,
          onTap: () => _showToolDetail(row),
        );
      case SubagentRow():
        return _SubagentLine(row: row);
      case TimelineMarkerRow():
        return _TimelineMarkerLine(row: row);
      case TurnHeaderRow():
        // Rendered separately, pinned to the visual bottom (_runningTurn).
        return const SizedBox.shrink();
      default:
        return const SizedBox.shrink();
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
          style: Theme.of(dialogContext)
              .textTheme
              .bodySmall
              ?.copyWith(height: 1.5),
        ),
      ),
    );
  }

  void _showToolDetail(ToolCallRow row) {
    final (_, verb, _) = _ToolCallLine._describe(row);
    final input = _ToolCallLine._prettyInput(row);
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
              const _DetailLabel('输入'),
              _MonoText(text: _ToolCallLine._trim(input)),
            ],
            if (output != null && output.isNotEmpty) ...[
              const _DetailLabel('输出'),
              _MonoText(text: _ToolCallLine._trim(output)),
            ],
            if (row.error != null && row.error!.isNotEmpty) ...[
              const _DetailLabel('错误'),
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

/// Small leading icon for a one-line row, colored by status.
Widget _statusIcon(BuildContext context, String status, IconData icon) {
  final scheme = Theme.of(context).colorScheme;
  if (status == 'running' || status == 'pending') {
    return SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: scheme.primary,
      ),
    );
  }
  final failed = status == 'error' || status == 'failed';
  return Icon(
    failed ? Icons.error_outline : icon,
    size: 15,
    color: failed ? scheme.error : scheme.onSurfaceVariant,
  );
}

// ---------- Row widgets ----------

class _MarkdownText extends StatelessWidget {
  final String text;
  final Color color;
  const _MarkdownText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final styleSheet =
        MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(color: color, height: 1.55),
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
        border: Border(
          left: BorderSide(color: scheme.outlineVariant, width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      listIndent: 20,
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: styleSheet,
    );
  }
}

class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
          child: SelectableText(
            text,
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop-style running-turn status: "工作中 12 分 11 秒". Ticks once a
/// second — the row stream alone only refreshes on poll/delta events.
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
    final scheme = Theme.of(context).colorScheme;
    final startedAt = widget.startedAt;
    final elapsed = startedAt == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - startedAt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            elapsed == null || elapsed < 0
                ? '工作中'
                : '工作中 ${_formatDuration(elapsed)}',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
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
class _ToolCallLine extends StatelessWidget {
  final ToolCallRow row;
  final VoidCallback onTap;

  const _ToolCallLine({
    required this.row,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, verb, preview) = _describe(row);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            _statusIcon(context, row.status, icon),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: verb,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (preview.isNotEmpty)
                      TextSpan(
                        text: ' $preview',
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
        final verb =
            running ? '正在执行' : failed ? '执行失败' : '已执行';
        return (Icons.terminal, verb, arg('command') ?? _extractJsonString(row.inputText, 'command') ?? '');
      case 'Read':
        return (
          Icons.description_outlined,
          '读取',
          arg('file_path') ?? _extractJsonString(row.inputText, 'file_path') ?? '',
        );
      case 'Edit':
        return (
          Icons.edit_outlined,
          '编辑',
          arg('file_path') ?? _extractJsonString(row.inputText, 'file_path') ?? '',
        );
      case 'Write':
        return (
          Icons.note_add_outlined,
          '写入',
          arg('file_path') ?? _extractJsonString(row.inputText, 'file_path') ?? '',
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
        final verb = running ? '正在运行' : failed ? '运行失败' : name;
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
    final m =
        RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)').firstMatch(raw);
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
        .mapIndexed((i, w) =>
            i == 0 ? '${w[0].toUpperCase()}${w.substring(1)}' : w)
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
    final summary =
        row.summaryText.isEmpty ? '子代理' : _firstLine(row.summaryText);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          _statusIcon(context, row.status, Icons.smart_toy_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.outline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonoText extends StatelessWidget {
  final String text;
  const _MonoText({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: scheme.onSurfaceVariant,
          height: 1.45,
        ),
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
      title: Text(title, style: Theme.of(context).textTheme.titleSmall),
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

class _DetailLabel extends StatelessWidget {
  final String text;
  const _DetailLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
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
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    decoration: todo.status == 'completed'
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color:
                                        todo.status == 'completed'
                                            ? scheme.onSurfaceVariant
                                            : scheme.onSurface,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _statusLabel(todo.status),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
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

// ---------- Approval / question bottom sheet ----------

/// Renders a list of pending requests (one bottom sheet per category —
/// approvals vs questions are separate entries). Each request shows its
/// prompt and the option buttons; AskUserQuestion requests show the
/// per-question selector rows plus a custom answer field.
class _RequestSheet extends StatefulWidget {
  final List<PendingRequest> requests;
  final Future<void> Function(PendingRequest request, Map<String, Object?> answer)
      onResolve;
  const _RequestSheet({required this.requests, required this.onResolve});

  @override
  State<_RequestSheet> createState() => _RequestSheetState();
}

/// One "page" of the horizontal question list — a (request, question) pair.
class _QuestionPage {
  final PendingRequest request;
  final InteractionQuestion question;
  const _QuestionPage(this.request, this.question);
}

class _RequestSheetState extends State<_RequestSheet> {
  late final PageController _pageController;
  int _page = 0;
  bool _submitting = false;

  /// Flatten all questions across the pending requests into one horizontal
  /// list — the user answers one question per page and swipes between them.
  late final List<_QuestionPage> _pages = [
    for (final request in widget.requests)
      for (final question in request.questions) _QuestionPage(request, question),
  ];

  /// question text -> chosen option values (value, else label).
  final Map<String, Set<String>> _selections = {};
  final Map<String, TextEditingController> _customControllers = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _customControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _customController(String question) =>
      _customControllers.putIfAbsent(question, TextEditingController.new);

  static String _optionIdentity(InteractionQuestionOption option) =>
      option.value.trim().isEmpty ? option.label : option.value;

  bool get _currentAnswered {
    final page = _pages[_page];
    final q = page.question;
    return (_selections[q.question]?.isNotEmpty ?? false) ||
        _customController(q.question).text.trim().isNotEmpty;
  }

  void _toggle(InteractionQuestion question, InteractionQuestionOption option) {
    final identity = _optionIdentity(option);
    setState(() {
      final selected = _selections.putIfAbsent(question.question, () => {});
      if (question.multiSelect) {
        if (!selected.remove(identity)) selected.add(identity);
      } else {
        selected
          ..clear()
          ..add(identity);
      }
    });
    // Single-choice questions are "answered" on tap: jump to the next page.
    if (!question.multiSelect && _page < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _goNext() {
    if (_page >= _pages.length - 1) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      // Resolve each pending request with the answers it owns.
      for (final request in widget.requests) {
        final questions = request.questions;
        final selections = <String, List<String>>{
          for (final q in questions)
            q.question: [
              ...?_selections[q.question],
              if (_customController(q.question).text.trim().isNotEmpty)
                _customController(q.question).text.trim(),
            ],
        };
        await widget.onResolve(request, {
          'action': 'accept',
          'content': buildQuestionAnswerContent(questions, selections),
        });
      }
      // Close the panel once the answers are away; the next readSession poll
      // drops the resolved request from the entries row.
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allQuestions = widget.requests.every((r) => r.isElicitation);
    final height = MediaQuery.sizeOf(context).height * 0.66;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Icon(
                    allQuestions
                        ? Icons.quiz_outlined
                        : Icons.verified_user_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      allQuestions ? '需要你的回答' : '需要批准',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  // Question position dots.
                  if (_pages.length > 1)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _pages.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            width: i == _page ? 14 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _page
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final page = _pages[i];
                  return _buildQuestionPage(scheme, page);
                },
              ),
            ),
            // Bottom actions.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (_page == _pages.length - 1) ...[
                    FilledButton(
                      onPressed: _submitting || !_currentAnswered
                          ? null
                          : _submit,
                      child: const Text('提交'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => widget.onResolve(
                              _pages[_page].request, {'action': 'cancel'}),
                      child: const Text('取消'),
                    ),
                  ] else
                    FilledButton(
                      onPressed: _currentAnswered ? _goNext : null,
                      child: const Text('下一题'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionPage(ColorScheme scheme, _QuestionPage page) {
    final q = page.question;
    final selected = _selections[q.question] ?? const <String>{};
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (q.header.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                q.header,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.tertiary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  q.question,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurface),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                q.multiSelect ? '可多选' : '单选',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final option in q.options)
            _QuestionOptionTile(
              option: option,
              multiSelect: q.multiSelect,
              selected: selected.contains(_optionIdentity(option)),
              onTap: _submitting ? null : () => _toggle(q, option),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _customController(q.question),
              enabled: !_submitting,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: q.multiSelect ? '其他回答（可多选后补充）' : '其他回答…',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One selectable option row: a radio/checkbox indicator, the option label,
/// and the description underneath (previously hidden behind a long-press
/// tooltip).
class _QuestionOptionTile extends StatelessWidget {
  final InteractionQuestionOption option;
  final bool multiSelect;
  final bool selected;
  final VoidCallback? onTap;

  const _QuestionOptionTile({
    required this.option,
    required this.multiSelect,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              multiSelect
                  ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
                  : (selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.label.isEmpty ? '（无标签）' : option.label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: selected ? scheme.primary : scheme.onSurface,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                  ),
                  if (option.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        option.description,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
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

// ---------- Token usage detail sheet ----------

class _TokenUsageSheet extends StatelessWidget {
  final ContextUsage usage;
  final Map<String, Object?>? tokenUsage;
  const _TokenUsageSheet({required this.usage, this.tokenUsage});

  static const _sourceLabels = <String, String>{
    'messages': '消息',
    'system_prompt': '系统提示词',
    'meta_user_context': '其他',
    'skills': '技能',
    'tool_prompt': '其他',
    'system_tool_schemas': '系统工具',
    'mcp_tool_schemas': 'MCP 工具',
  };

  static String _sourceLabel(String source) =>
      _sourceLabels[source] ?? source;

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
    final hitRate = usage.cacheHitRate ??
        _cumulativeHitRate(tokenUsage);
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
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
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
                Text(
                  '平均缓存命中率',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                Text(
                  hitRate == null
                      ? '—'
                      : '${(hitRate * 100).toStringAsFixed(1)}%',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
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
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static double? _cumulativeHitRate(Map<String, Object?>? token) {
    if (token == null) return null;
    final read = token['cacheReadTokens'];
    final input = token['inputTokens'];
    if (read is num && input is num && input > 0) {
      return (read / input).clamp(0.0, 1.0);
    }
    return null;
  }
}
