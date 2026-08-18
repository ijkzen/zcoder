import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../protocol/services/services.dart';
import '../protocol/topics/topic_models.dart';
import 'conversation_page.dart';
import 'attachment_picker.dart';
import 'chat_composer.dart';
import 'model_config_sheet.dart';
import 'pull_to_refresh.dart';
import 'reconnect_banner.dart';

/// The provider/model/thought/mode sent when creating a session: the manual
/// picker selection (draft) wins per value; anything unset falls back to the
/// workspace-synced current — the exact value the label above the input bar
/// shows. Forcing the synced value instead of sending nothing keeps the phone
/// label and the executed model in agreement; the desktop otherwise resolves
/// its own default, which has been observed to diverge from the synced one.
SessionModelConfig effectiveSessionModelConfig({
  SessionModelConfig? workspace,
  String? draftProvider,
  String? draftModel,
  String? draftThought,
  String? draftMode,
}) => SessionModelConfig(
  provider: draftProvider ?? workspace?.provider,
  model: draftModel ?? workspace?.model,
  thoughtLevel: draftThought ?? workspace?.thoughtLevel,
  mode: draftMode ?? workspace?.mode,
);

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
  /// Task-list view: 0 = all, 1 = pinned, 2 = archived.
  int _tab = 0;

  /// Search box toggled from the AppBar (hidden in multi-select mode).
  bool _searching = false;
  final _searchController = TextEditingController();
  String get _query => _searchController.text.trim();

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

  /// Collaboration mode for the next created session (from the workspace's
  /// prepareWorkspace configOptions).
  String? _draftMode;

  @override
  void initState() {
    super.initState();
    _loadPersistedPrefs();
    _loadWorkspaceConfig();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedPrefs() async {
    try {
      final prefs = await widget.app.loadWorkspaceModelPrefs(
        widget.workspace.workspaceKey,
      );
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
    if (!_configLoading) {
      setState(() => _configLoading = true);
      try {
        // Re-read the registry on every open so providers deleted since the
        // page loaded (desktop settings or this page) don't linger in the
        // picker; when offline, keep the page-load snapshot.
        config = await widget.app.fetchWorkspaceModelConfig(refresh: true);
        _workspaceConfig = config;
      } catch (_) {
        // Offline — _workspaceConfig already holds the last snapshot.
      } finally {
        if (mounted) setState(() => _configLoading = false);
      }
    }
    if (!mounted || config == null) return;
    if (config.availableModels.isEmpty &&
        config.availableThoughtLevels.isEmpty) {
      return;
    }
    // Collaboration-mode options + workspace current values come from
    // prepareWorkspace's configOptions (fall back to canonical sets); the
    // workspace-level mode from readWorkspaceState settings wins when present.
    final prep = await widget.app.fetchWorkspacePrep();
    final modeOptions = _prepOptionValues(
      prep,
      const ['mode', 'collaborationMode'],
      const ['build', 'edit', 'plan', 'yolo'],
    );
    final currentMode =
        _draftMode ??
        config.mode ??
        _prepCurrentValue(prep, const ['mode', 'collaborationMode']);
    if (!mounted) return;
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
        modeOptions: modeOptions,
        currentMode: currentMode,
        onModeChanged: (mode) async {
          if (!mounted) return;
          setState(() => _draftMode = mode);
        },
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
    if (_draftProvider == null &&
        _draftModel == null &&
        _draftThought == null) {
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

  /// The model actually used to create the next session (both here and in
  /// [effectiveSessionModelConfig]): picker selection where set, else the
  /// workspace-synced current.
  SessionModelConfig get _sessionModelConfig => effectiveSessionModelConfig(
    workspace: _workspaceConfig,
    draftProvider: _draftProvider,
    draftModel: _draftModel,
    draftThought: _draftThought,
    draftMode: _draftMode,
  );

  /// ChatComposer onSend: returns true when the session was created (the
  /// composer then clears itself); on failure the draft stays (TC-SES-024).
  Future<bool> _createSession(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return false;
    // With staged attachments the flow is: create an EMPTY session (no
    // firstInput — uploads need the sessionId first) → upload each file →
    // sendText(text + attachment descriptors) so everything lands as ONE
    // first message. Pressing send again after a failure resumes the flow
    // (_pendingSessionId keeps the already-created session).
    if (_pendingAttachments.isNotEmpty || _pendingSessionId != null) {
      return _createWithAttachments(text);
    }
    try {
      final cfg = _sessionModelConfig;
      final sessionId = await widget.app
          .createSession(
            text,
            provider: cfg.provider,
            model: cfg.model,
            thoughtLevel: cfg.thoughtLevel,
            mode: cfg.mode,
          )
          .timeout(const Duration(seconds: 15));
      // The selection stays: it is persisted for the next session too.
      // Jump straight into the new session; without an id in the command
      // result the session still shows up in the list on the next refresh.
      if (mounted && sessionId != null) {
        // Not awaited: onSend must return immediately so the composer clears
        // and an open expanded editor closes — the conversation page lands
        // on its own.
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ConversationPage(
                app: widget.app,
                sessionId: sessionId,
                title: text,
              ),
            ),
          ),
        );
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建会话失败：$e')));
      }
      return false;
    }
  }

  Future<bool> _createWithAttachments(String text) async {
    var sessionId = _pendingSessionId;
    if (sessionId == null) {
      try {
        final cfg = _sessionModelConfig;
        sessionId = await widget.app
            .createSession(
              null,
              provider: cfg.provider,
              model: cfg.model,
              thoughtLevel: cfg.thoughtLevel,
              mode: cfg.mode,
            )
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('创建会话失败：$e')));
        }
        return false;
      }
      if (sessionId == null) {
        // Accepted without an id — we can't target the session for uploads.
        // Keep text and staged files so nothing is lost.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('会话已创建但未返回会话 id，请从列表进入会话后重新添加附件')),
          );
        }
        return false;
      }
      _pendingSessionId = sessionId;
    }
    // Upload whatever is still staged (after a failure the loop resumes where
    // it stopped — succeeded descriptors accumulate in _uploadedDescriptors).
    for (final p in List<PickedAttachment>.of(_pendingAttachments)) {
      setState(() {
        _uploading = true;
        _uploadingName = p.name;
        _uploadProgress = 0;
      });
      try {
        final descriptor = await widget.app.uploadAttachment(
          sessionId,
          fileName: p.name,
          mime: p.mime,
          bytes: p.bytes,
          onProgress: (progress) {
            if (mounted) setState(() => _uploadProgress = progress);
          },
        );
        _pendingAttachments.remove(p);
        _uploadedDescriptors.add(descriptor);
      } catch (e) {
        if (mounted) {
          setState(() => _uploading = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('附件上传失败：$e（修正后再点发送可续传）')));
        }
        return false;
      }
    }
    if (mounted) setState(() => _uploading = false);
    // The first message carries text + all attachment descriptors as one.
    try {
      final result = await widget.app
          .sendText(
            text,
            attachments: List<Map<String, Object?>>.of(_uploadedDescriptors),
            sessionId: sessionId,
          )
          .timeout(const Duration(seconds: 15));
      if (result['status'] == 'rejected' && mounted) {
        final reason = result['reasonCode']?.toString() ?? '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reason.isEmpty ? '消息被拒绝发送' : '消息被拒绝发送：$reason'),
          ),
        );
        return false;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失败：$e（再点发送可重试）')));
      }
      return false;
    }
    _pendingSessionId = null;
    _uploadedDescriptors.clear();
    if (mounted) {
      // Not awaited — same reason as the no-attachment path above.
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ConversationPage(
              app: widget.app,
              sessionId: sessionId!,
              title: text,
            ),
          ),
        ),
      );
    }
    return true;
  }

  // ---------- 新建任务暂存附件 ----------

  /// Picked files staged locally until the session exists — uploaded during
  /// the send flow so they ride the first message.
  final _pendingAttachments = <PickedAttachment>[];

  /// Mid-flow state of the attachment path: the session already created (its
  /// first message not yet sent) and the descriptors uploaded so far. Both
  /// exist purely so a failed send can be resumed by pressing send again.
  String? _pendingSessionId;
  final _uploadedDescriptors = <Map<String, Object?>>[];
  bool _uploading = false;
  String _uploadingName = '';
  double _uploadProgress = 0;

  Future<void> _stageAttachment() async {
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
    _pendingAttachments.add(picked);
    setState(() {});
  }

  Widget? _buildPendingAttachmentBar() {
    if (_pendingAttachments.isEmpty && !_uploading) return null;
    // Mid-flow (session created, uploads running/failed) the chips are locked:
    // their bytes may already be part-uploaded, so deleting would strand the
    // descriptor on the desktop.
    final locked = _pendingSessionId != null;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final a in _pendingAttachments)
          InputChip(
            label: Text(a.name),
            avatar: Icon(
              a.mime.startsWith('image/')
                  ? Icons.image_outlined
                  : Icons.insert_drive_file_outlined,
              size: 18,
            ),
            onDeleted: locked
                ? null
                : () => setState(() => _pendingAttachments.remove(a)),
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

  // ---------- 条目「更多」菜单操作：重命名 / 归档 ----------

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已重命名')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重命名失败：$e')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已归档')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('归档失败：$e')));
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
      // Running sessions are never archivable — select-all skips them.
      final allIds = widget.app.sessions
          .where((s) => s.taskId != null && !s.isRunning)
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
      final failed = await widget.app.archiveSessions(_selectedIds.toList());
      if (!mounted) return;
      setState(() {
        _multiSelect = false;
        _selectedIds.clear();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failed == 0
                  ? '已归档 $count 个会话'
                  : '已归档 ${count - failed} 个，$failed 个失败',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('批量归档失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _batchArchiving = false);
    }
  }

  // ---------- Model label above the input (always visible) ----------

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

  /// Sessions of the active tab, filtered by the search query.
  List<Workspace> _visibleSessions() {
    final List<Workspace> base = switch (_tab) {
      1 => widget.app.pinnedSessions,
      2 => widget.app.archivedSessions,
      _ => widget.app.sessions,
    };
    final query = _query.toLowerCase();
    if (query.isEmpty) return base;
    return base
        .where((s) => (s.taskTitle ?? '').toLowerCase().contains(query))
        .toList();
  }

  Widget _buildTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: SegmentedButton<int>(
        segments: const [
          ButtonSegment(
            value: 0,
            label: Text('全部'),
            icon: Icon(Icons.forum_outlined, size: 16),
          ),
          ButtonSegment(
            value: 1,
            label: Text('置顶'),
            icon: Icon(Icons.push_pin_outlined, size: 16),
          ),
          ButtonSegment(
            value: 2,
            label: Text('已归档'),
            icon: Icon(Icons.archive_outlined, size: 16),
          ),
        ],
        selected: {_tab},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => setState(() {
          _tab = selection.first;
          _searching = false;
        }),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: '搜索会话标题…',
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: IconButton(
            tooltip: '清除',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () {
              _searchController.clear();
              setState(() {});
            },
          ),
        ),
      ),
    );
  }

  Future<void> _togglePin(Workspace session) async {
    final taskId = session.taskId;
    if (taskId == null) return;
    try {
      await widget.app.setTaskPinned(taskId, pinned: !session.pinned);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(session.pinned ? '已取消置顶' : '已置顶')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$e')));
      }
    }
  }

  Future<void> _unarchiveSession(Workspace session, String title) async {
    try {
      await widget.app.unarchiveSession(session.taskId!);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已恢复「$title」')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败：$e')));
      }
    }
  }

  /// 输入框上方的提示行：模型 · 思考等级 · 协作模式（纯值，无图标）。
  /// 模型部分草稿优先；协作模式取草稿或项目的当前值
  /// （readWorkspaceState settings.mode.current）。
  Widget _buildModelLabel(ColorScheme scheme) {
    final hasDraft =
        _draftProvider != null || _draftModel != null || _draftThought != null;
    final String modelText;
    if (hasDraft) {
      modelText = [
        _providerDisplay(_draftProvider),
        _draftModel,
        _draftThought,
      ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    } else {
      final cfg = _workspaceConfig;
      modelText =
          (cfg == null || (cfg.model == null && cfg.thoughtLevel == null))
          ? '工作区默认'
          : [
              _providerDisplay(cfg.provider),
              cfg.model,
              cfg.thoughtLevel,
            ].whereType<String>().join(' · ');
    }
    final mode = _draftMode ?? _workspaceConfig?.mode;
    final modeText = (mode == null || mode.isEmpty) ? '' : mode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              modelText,
              textAlign: TextAlign.left,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (modeText.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(
              modeText,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              maxLines: 1,
            ),
          ],
        ],
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected =
        _multiSelect &&
        _selectedIds.length >=
            widget.app.sessions.where((s) => !s.isRunning).length &&
        widget.app.sessions.isNotEmpty;
    // Back exits multi-select first instead of popping the page (Gmail/微信
    // convention); only a second back press leaves the page.
    return PopScope(
      canPop: !_multiSelect,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _multiSelect) _exitMultiSelect();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _multiSelect
              ? IconButton(
                  tooltip: '退出多选',
                  onPressed: _exitMultiSelect,
                  icon: const Icon(Icons.close),
                )
              : null,
          title: Text(
            _multiSelect
                ? (_selectedIds.isEmpty
                      ? '选择会话'
                      : '已选 ${_selectedIds.length} 项')
                : (widget.workspace.workspaceLabel.isEmpty
                      ? widget.workspace.workspacePath
                      : widget.workspace.workspaceLabel),
          ),
          actions: _multiSelect
              ? [
                  IconButton(
                    tooltip: allSelected ? '取消全选' : '全选',
                    onPressed: _toggleSelectAll,
                    icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
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
                    tooltip: '搜索会话',
                    onPressed: () => setState(() => _searching = !_searching),
                    icon: const Icon(Icons.search),
                  ),
                  // 已归档 tab 没有可归档的东西：隐藏批量归档入口。
                  if (_tab != 2)
                    IconButton(
                      tooltip: '批量归档',
                      onPressed: () => setState(() {
                        _multiSelect = true;
                        _tab = 0;
                      }),
                      icon: const Icon(Icons.checklist),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_vert),
                    onSelected: (value) {
                      switch (value) {
                        case 'model':
                          if (!_configLoading) _pickModelConfig();
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'model',
                        enabled: !_configLoading,
                        child: const ListTile(
                          leading: Icon(Icons.tune, size: 20),
                          title: Text('模型与思考等级'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
        ),
        // The input bar lives in the body Column (not bottomNavigationBar) so it
        // rides up with the IME exactly like the conversation page does.
        body: Column(
          children: [
            ReconnectBanner(app: widget.app),
            if (!_multiSelect) ...[
              if (_searching) _buildSearchBar(),
              _buildTabs(),
            ],
            Expanded(
              child: ListenableBuilder(
                listenable: widget.app,
                builder: (context, _) {
                  final sessions = _visibleSessions();
                  if (sessions.isEmpty) {
                    return RefreshIndicator(
                      onRefresh: widget.app.refreshSessions,
                      child: RefreshableEmptyState(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _tab == 2
                                    ? Icons.archive_outlined
                                    : Icons.forum_outlined,
                                size: 56,
                                color: scheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _tab == 2
                                    ? '没有已归档的会话'
                                    : (_query.isNotEmpty
                                          ? '没有匹配的会话'
                                          : '这个工作区还没有会话'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              if (_tab != 2 && _query.isEmpty)
                                Text(
                                  '在下方输入框直接开始一个新任务',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: widget.app.refreshSessions,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: sessions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final s = sessions[i];
                        final running = s.isRunning;
                        final title =
                            (s.taskTitle != null && s.taskTitle!.isNotEmpty)
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
                                ? (running
                                      // Running sessions can't be archived — keep
                                      // the running marker instead of a checkbox.
                                      ? Icon(
                                          Icons.play_arrow,
                                          color: scheme.outline,
                                        )
                                      : Icon(
                                          selected
                                              ? Icons.check_circle
                                              : Icons.radio_button_unchecked,
                                          color: selected
                                              ? scheme.primary
                                              : scheme.outline,
                                        ))
                                : SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: Center(
                                      child: () {
                                        final color = _statusColor(s.displayStatus);
                                        if (color == null) return const SizedBox.shrink();
                                        return AnimatedContainer(
                                          width: 8,
                                          height: 8,
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          curve: Curves.easeOut,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: color,
                                          ),
                                        );
                                      }(),
                                    ),
                                  ),
                            title: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // Unread sessions render bold with a dot.
                              style: (s.unreadAt != null && _tab != 2)
                                  ? const TextStyle(fontWeight: FontWeight.w700)
                                  : null,
                            ),
                            subtitle: Text(
                              _statusLabel(s.displayStatus),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Archived tab: restore button; otherwise the unread
                            // dot (multi-select mode hides both).
                            trailing: _multiSelect
                                ? null
                                : (_tab == 2
                                      ? IconButton(
                                          tooltip: '取消归档',
                                          onPressed: () =>
                                              _unarchiveSession(s, title),
                                          icon: const Icon(
                                            Icons.unarchive_outlined,
                                          ),
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (s.unreadAt != null)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 8,
                                                ),
                                                child: Icon(
                                                  Icons.circle,
                                                  size: 8,
                                                  color: scheme.primary,
                                                ),
                                              ),
                                            PopupMenuButton<String>(
                                              tooltip: '更多操作',
                                              onSelected: (value) {
                                                switch (value) {
                                                  case 'pin':
                                                    _togglePin(s);
                                                    break;
                                                  case 'rename':
                                                    _renameSession(s, title);
                                                    break;
                                                  case 'archive':
                                                    _archiveSession(s, title);
                                                    break;
                                                }
                                              },
                                              itemBuilder: (context) => [
                                                PopupMenuItem(
                                                  value: 'pin',
                                                  child: ListTile(
                                                    leading: Icon(
                                                      s.pinned
                                                          ? Icons
                                                                .push_pin_outlined
                                                          : Icons.push_pin,
                                                      size: 20,
                                                    ),
                                                    title: Text(
                                                      s.pinned ? '取消置顶' : '置顶',
                                                    ),
                                                    contentPadding:
                                                        EdgeInsets.zero,
                                                  ),
                                                ),
                                                PopupMenuItem(
                                                  value: 'rename',
                                                  child: const ListTile(
                                                    leading: Icon(
                                                      Icons.edit_outlined,
                                                      size: 20,
                                                    ),
                                                    title: Text('重命名'),
                                                    contentPadding:
                                                        EdgeInsets.zero,
                                                  ),
                                                ),
                                                // 运行中会话不可归档（TC-SES-101），
                                                // 菜单不出现「归档」项。
                                                if (!running)
                                                  PopupMenuItem(
                                                    value: 'archive',
                                                    child: const ListTile(
                                                      leading: Icon(
                                                        Icons.archive_outlined,
                                                        size: 20,
                                                      ),
                                                      title: Text('归档'),
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        )),
                            onTap: _multiSelect
                                ? () {
                                    if (running) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('运行中的会话不能归档'),
                                        ),
                                      );
                                      return;
                                    }
                                    setState(() {
                                      if (!_selectedIds.remove(id)) {
                                        _selectedIds.add(id);
                                      }
                                    });
                                  }
                                : () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ConversationPage(
                                          app: widget.app,
                                          sessionId: id,
                                          title: title,
                                          archived: s.archived,
                                        ),
                                      ),
                                    );
                                  },
                            // Long-press enters multi-select with this item
                            // checked (the standard bulk-action entry gesture).
                            // The archived tab has no batch-archive entry, so the
                            // gesture is disabled there too.
                            onLongPress: _multiSelect || _tab == 2
                                ? null
                                : () => setState(() {
                                    _multiSelect = true;
                                    _selectedIds.add(id);
                                  }),
                          ),
                        );
                        return card;
                      },
                    ),
                  );
                },
              ),
            ),
            _buildModelLabel(scheme),
            ChatComposer(
              app: widget.app,
              hintText: '给 agent 下达新任务…',
              onPickAttachment: _stageAttachment,
              header: _buildPendingAttachmentBar(),
              onSend: _createSession,
            ),
          ],
        ),
      ),
    );
  }

  /// Returns the color for the session status dot.
  /// [status] is [Workspace.displayStatus] (idle | running | completed | error).
  Color? _statusColor(String status) {
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'running':
        return Colors.blue;
      case 'error':
        return Colors.red;
      case 'draft':
        return Colors.yellow;
      default:
        return null; // No dot for idle and other statuses
    }
  }

  /// Subtitle label for a session row, mirrored from [Workspace.displayStatus]
  /// so non-running statuses (error, draft, idle) never masquerade as
  /// completed. Uses the same labels as [SessionPhase.zh].
  String _statusLabel(String status) {
    switch (status) {
      case 'running':
        return '运行中';
      case 'completed':
        return '已完成';
      case 'error':
        return '出错';
      case 'draft':
        return '草稿';
      case 'idle':
        return '空闲';
      default:
        return status;
    }
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
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
