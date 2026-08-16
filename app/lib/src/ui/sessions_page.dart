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

  /// The workspace's model registry, loaded lazily when the picker opens.
  SessionModelConfig? _workspaceConfig;
  bool _configLoading = false;

  /// Draft model/thought level for the next created session.
  String? _draftProvider;
  String? _draftModel;
  String? _draftThought;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
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
        },
      ),
    );
  }

  /// The picker shows the draft selection (highlighted) instead of the
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

  void _clearDraft() {
    setState(() {
      _draftProvider = null;
      _draftModel = null;
      _draftThought = null;
    });
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
      _clearDraft();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建会话失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String get _draftLabel {
    final parts = <String>[
      if (_draftModel != null) _draftModel!,
      if (_draftThought != null) _draftThought!,
    ];
    return parts.join(' · ');
  }


  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workspace.workspaceLabel.isEmpty
            ? widget.workspace.workspacePath
            : widget.workspace.workspaceLabel),
        actions: [
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
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
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
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ConversationPage(
                              app: widget.app,
                              sessionId: s.taskId!,
                              title: title,
                            ),
                          ));
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_draftModel != null || _draftThought != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              child: Row(
                children: [
                  Icon(Icons.tune, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '新会话将使用：$_draftLabel',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '清除',
                    onPressed: _clearDraft,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
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
