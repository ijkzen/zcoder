import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../session/models.dart';
import 'conversation_page.dart';
import 'model_config_sheet.dart';

/// Screen 3: sessions of the active workspace. Also the entry point for
/// starting a new session (bottom input bar).
class SessionsPage extends StatefulWidget {
  final AppController app;
  final Workspace workspace;
  const SessionsPage({super.key, required this.app, required this.workspace});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final _inputController = TextEditingController();
  bool _sending = false;

  /// The workspace's model registry, loaded on page open (also used by the
  /// picker and to render the fixed model label above the input bar).
  SessionModelConfig? _workspaceConfig;
  bool _configLoading = false;

  /// Model/thought level for the next created session. Seeded from the
  /// per-workspace persisted preference so the user doesn't re-pick it every
  /// time (the workspace default model can be broken on some hosts).
  String? _draftProvider;
  String? _draftModel;
  String? _draftThought;

  @override
  void initState() {
    super.initState();
    _loadPersistedPrefs();
    _loadWorkspaceConfig();
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedPrefs() async {
    try {
      final prefs =
          await widget.app.loadWorkspaceModelPrefs(widget.workspace.workspaceKey);
      if (!mounted || prefs == null) return;
      setState(() {
        _draftProvider = prefs.provider;
        _draftModel = prefs.model;
        _draftThought = prefs.thoughtLevel;
      });
    } catch (_) {
      // Preferences are a convenience — ignore read failures.
    }
  }

  Future<void> _loadWorkspaceConfig() async {
    if (_configLoading) return;
    setState(() => _configLoading = true);
    try {
      _workspaceConfig = await widget.app.fetchWorkspaceModelConfig();
    } catch (_) {
      // Offline or not ready yet — the picker retries on open and the label
      // falls back to the persisted selection only.
    } finally {
      if (mounted) setState(() => _configLoading = false);
    }
  }

  Future<void> _pickModelConfig() async {
    var config = _workspaceConfig;
    if (config == null && !_configLoading) {
      setState(() => _configLoading = true);
      try {
        config = await widget.app.fetchWorkspaceModelConfig();
        _workspaceConfig = config;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取模型配置失败：$e')),
          );
        }
        if (mounted) setState(() => _configLoading = false);
        return;
      }
      if (mounted) setState(() => _configLoading = false);
    }
    if (!mounted || config == null) return;
    if (config.availableModels.isEmpty &&
        config.availableThoughtLevels.isEmpty) {
      return;
    }
    final baseConfig = config;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      enableDrag: false,
      builder: (sheetContext) => ModelConfigSheet(
        config: _draftConfig(baseConfig),
        subtitle: '仅用于本次创建的新会话',
        autoClose: false,
        onApply: (provider, model, thoughtLevel) async {
          if (!mounted) return;
          setState(() {
            _draftProvider = provider;
            _draftModel = model;
            _draftThought = thoughtLevel;
          });
          try {
            await widget.app.saveWorkspaceModelPrefs(
              widget.workspace.workspaceKey,
              provider: provider,
              model: model,
              thoughtLevel: thoughtLevel,
            );
          } catch (_) {
            // Persistence failing must not block the in-memory selection.
          }
        },
      ),
    );
  }

  /// The picker shows the persisted selection (highlighted) instead of the
  /// workspace's current defaults once the user has chosen something.
  SessionModelConfig _draftConfig(SessionModelConfig base) {
    if (_draftProvider == null && _draftModel == null && _draftThought == null) {
      return base;
    }
    return SessionModelConfig(
      provider: _draftProvider ?? base.provider,
      model: _draftModel ?? base.model,
      thoughtLevel: _draftThought ?? base.thoughtLevel,
      availableModels: base.availableModels,
      availableThoughtLevels: base.availableThoughtLevels,
    );
  }

  /// Drops the persisted selection — new sessions fall back to the workspace
  /// defaults again.
  Future<void> _clearDraft() async {
    setState(() {
      _draftProvider = null;
      _draftModel = null;
      _draftThought = null;
    });
    try {
      await widget.app.clearWorkspaceModelPrefs(widget.workspace.workspaceKey);
    } catch (_) {}
  }

  Future<void> _createSession() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.app
          .createSession(
            text,
            provider: _draftProvider,
            model: _draftModel,
            thoughtLevel: _draftThought,
          )
          .timeout(const Duration(seconds: 15));
      _inputController.clear();
      // The selection stays: it is persisted for the next session too.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建会话失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------- Swipe actions: rename / archive ----------

  Future<void> _renameSession(Workspace session, String currentTitle) async {
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _RenameSessionDialog(initialTitle: currentTitle),
    );
    if (result == null || result.isEmpty || result == currentTitle) return;
    try {
      await widget.app.renameSession(session.taskId!, result);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已重命名')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
      }
    }
  }

  Future<void> _archiveSession(Workspace session, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('归档会话'),
        content: Text('确定要归档「$title」吗？归档后将不再显示在会话列表中。'),
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
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.app.archiveSession(session.taskId!);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已归档')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('归档失败：$e')));
      }
    }
  }

  // ---------- Multi-select: batch archive ----------

  bool _multiSelect = false;
  final Set<String> _selectedIds = {};
  bool _batchArchiving = false;

  void _exitMultiSelect() => setState(() {
        _multiSelect = false;
        _selectedIds.clear();
      });

  void _toggleSelectAll() {
    setState(() {
      final sessions = widget.app.sessions;
      final allIds = sessions
          .where((s) => s.taskId != null)
          .map((s) => s.taskId!)
          .toSet();
      if (_selectedIds.length >= allIds.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(allIds);
      }
    });
  }

  Future<void> _batchArchive() async {
    if (_selectedIds.isEmpty || _batchArchiving) return;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量归档'),
        content: Text('确定要归档选中的 $count 个会话吗？归档后将不再显示在会话列表中。'),
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
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _batchArchiving = true);
    try {
      final failed =
          await widget.app.archiveSessions(_selectedIds.toList());
      if (!mounted) return;
      setState(() {
        _multiSelect = false;
        _selectedIds.clear();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed == 0
              ? '已归档 $count 个会话'
              : '已归档 ${count - failed} 个，$failed 个失败'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('批量归档失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _batchArchiving = false);
    }
  }

  // ---------- Model label above the input (always visible) ----------

  /// Display name for a provider id, from the workspace registry.
  String? _providerDisplay(String? providerId) {
    if (providerId == null) return null;
    final models = _workspaceConfig?.availableModels;
    if (models != null) {
      for (final m in models) {
        if (m.provider == providerId) {
          final label = m.providerLabel;
          if (label != null && label.isNotEmpty) return label;
          break;
        }
      }
    }
    return providerId;
  }

  Widget _buildModelLabel(ColorScheme scheme) {
    final hasDraft = _draftProvider != null ||
        _draftModel != null ||
        _draftThought != null;
    final String text;
    if (hasDraft) {
      text = [
        _providerDisplay(_draftProvider),
        _draftModel,
        _draftThought,
      ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    } else {
      final cfg = _workspaceConfig;
      text = (cfg == null || (cfg.model == null && cfg.thoughtLevel == null))
          ? '工作区默认'
          : [
              _providerDisplay(cfg.provider),
              cfg.model,
              cfg.thoughtLevel,
            ].whereType<String>().join(' · ');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: Row(
        children: [
          Icon(Icons.tune, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '新会话将使用：$text',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasDraft)
            IconButton(
              tooltip: '清除，改用工作区默认',
              onPressed: _clearDraft,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected =
        _multiSelect && _selectedIds.length >= widget.app.sessions.length;
    return Scaffold(
      appBar: AppBar(
        leading: _multiSelect
            ? IconButton(
                tooltip: '退出多选',
                onPressed: _exitMultiSelect,
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(_multiSelect
            ? (_selectedIds.isEmpty ? '选择会话' : '已选 ${_selectedIds.length} 项')
            : (widget.workspace.workspaceLabel.isEmpty
                ? widget.workspace.workspacePath
                : widget.workspace.workspaceLabel)),
        actions: _multiSelect
            ? [
                IconButton(
                  tooltip: allSelected ? '取消全选' : '全选',
                  onPressed: _toggleSelectAll,
                  icon: Icon(
                      allSelected ? Icons.deselect : Icons.select_all),
                ),
                IconButton(
                  tooltip: '归档所选',
                  onPressed: (_selectedIds.isEmpty || _batchArchiving)
                      ? null
                      : _batchArchive,
                  icon: _batchArchiving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.archive),
                ),
              ]
            : [
                IconButton(
                  tooltip: '批量归档',
                  onPressed: () => setState(() => _multiSelect = true),
                  icon: const Icon(Icons.checklist),
                ),
                IconButton(
                  tooltip: '新建会话的模型与思考等级',
                  onPressed: _configLoading ? null : _pickModelConfig,
                  icon: const Icon(Icons.tune),
                ),
              ],
      ),
      // The input bar lives in the body Column (not bottomNavigationBar) so it
      // rides up with the IME exactly like the conversation page does.
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: widget.app,
              builder: (context, _) {
                final sessions = widget.app.sessions;
                if (sessions.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.forum_outlined,
                              size: 56, color: scheme.outline),
                          const SizedBox(height: 12),
                          Text(
                            '这个工作区还没有会话',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '在下方输入框直接开始一个新任务',
                            style:
                                TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  itemCount: sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    final running = s.isRunning;
                    final title = (s.taskTitle != null && s.taskTitle!.isNotEmpty)
                        ? s.taskTitle!
                        : '未命名会话';
                    final id = s.taskId!;
                    final selected = _selectedIds.contains(id);
                    final card = Card(
                      margin: EdgeInsets.zero,
                      // Zero margin: the action buttons ride flush against the
                      // card's right edge (spacing comes from the list).
                      color: (_multiSelect && selected)
                          ? scheme.surfaceContainerHighest
                          : null,
                      child: ListTile(
                        leading: _multiSelect
                            ? Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: selected
                                    ? scheme.primary
                                    : scheme.outline,
                              )
                            : CircleAvatar(
                                backgroundColor: running
                                    ? scheme.primaryContainer
                                    : scheme.surfaceContainerHighest,
                                child: Icon(
                                  running ? Icons.play_arrow : Icons.check,
                                  size: 18,
                                  color: running
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                        title: Text(title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          running ? '运行中' : '已完成',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: _multiSelect
                            ? () => setState(() {
                                  if (!_selectedIds.remove(id)) {
                                    _selectedIds.add(id);
                                  }
                                })
                            : () {
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => ConversationPage(
                                    app: widget.app,
                                    sessionId: id,
                                    title: title,
                                  ),
                                ));
                              },
                        // Long-press enters multi-select with this item
                        // checked (the standard bulk-action entry gesture).
                        onLongPress: _multiSelect
                            ? null
                            : () => setState(() {
                                  _multiSelect = true;
                                  _selectedIds.add(id);
                                }),
                      ),
                    );
                    if (_multiSelect) return card;
                    return _SwipeActionTile(
                      onRename: () => _renameSession(s, title),
                      onArchive: () => _archiveSession(s, title),
                      child: card,
                    );
                  },
                );
              },
            ),
          ),
          _buildModelLabel(scheme),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _createSession(),
                      decoration: const InputDecoration(
                        hintText: '给 agent 下达新任务…',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _createSession,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rename dialog. Owns its TextEditingController in State so the controller
/// is disposed only after the dialog's TextField is unmounted (disposing it
/// right after `await showDialog` trips a framework assertion).
class _RenameSessionDialog extends StatefulWidget {
  final String initialTitle;
  const _RenameSessionDialog({required this.initialTitle});

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final _controller = TextEditingController(text: widget.initialTitle);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(hintText: '会话名称'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// A list tile with iOS-style swipe actions: the two buttons hang off the
/// card's right edge, parked beyond the tile's clip (invisible), and a
/// left-drag translates card + buttons together so the buttons are pulled
/// into view by the card itself.
class _SwipeActionTile extends StatefulWidget {
  final Widget child;
  final VoidCallback onRename;
  final VoidCallback onArchive;

  const _SwipeActionTile({
    required this.child,
    required this.onRename,
    required this.onArchive,
  });

  @override
  State<_SwipeActionTile> createState() => _SwipeActionTileState();
}

class _SwipeActionTileState extends State<_SwipeActionTile> {
  static const _actionWidth = 72.0;
  static const _gap = 8.0;
  static const _revealExtent = _actionWidth * 2 + _gap;

  double _drag = 0; // current offset, 0 (closed) … -_revealExtent (open)
  bool _open = false;
  bool _dragging = false;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _drag = (_drag + details.delta.dx).clamp(-_revealExtent, 0.0).toDouble();
    });
  }

  void _onDragEnd(DragEndDetails details) {
    setState(() {
      _dragging = false;
      _open = _drag < -_revealExtent / 2;
    });
  }

  void _close() => setState(() {
        _open = false;
        _drag = 0;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final tileWidth = constraints.maxWidth;
      final target = _dragging ? _drag : (_open ? -_revealExtent : 0.0);
      // Two layers, both within the tile's own bounds (a single wide strip
      // would be unreachable: RenderBox.hitTest rejects positions outside
      // its size). The card slides left; the action strip slides in from
      // beyond the right edge by the same amount, staying flush with the
      // card's right edge — iOS-style "pulled out by the card" motion.
      return ClipRect(
        child: SizedBox(
          width: tileWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            // While open the card absorbs taps (first tap closes the actions
            // instead of opening the session); while closed the ListTile's
            // own tap recognizer, being deeper, wins the arena.
            onTap: _open ? _close : null,
            child: Stack(
              children: [
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _revealExtent + target),
                    duration: _dragging
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    builder: (context, actionOffset, child) =>
                        Transform.translate(
                      offset: Offset(actionOffset, 0),
                      child: child,
                    ),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _actionButton(
                            icon: Icons.edit_outlined,
                            label: '重命名',
                            backgroundColor: scheme.secondaryContainer,
                            foregroundColor: scheme.onSecondaryContainer,
                            onTap: () {
                              _close();
                              widget.onRename();
                            },
                          ),
                          const SizedBox(width: _gap),
                          _actionButton(
                            icon: Icons.archive_outlined,
                            label: '归档',
                            backgroundColor: scheme.errorContainer,
                            foregroundColor: scheme.onErrorContainer,
                            onTap: () {
                              _close();
                              widget.onArchive();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: target),
                  duration: _dragging
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  builder: (context, offset, child) => Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                  child: AbsorbPointer(
                    absorbing: _open,
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: _actionWidth,
      child: Material(
        color: backgroundColor,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: foregroundColor),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: foregroundColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
