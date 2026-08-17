/// 模型提供商管理（model-provider 通道）：列表 / 启停 / 删除 / 添加。
/// 入口在设备页的二级菜单里——手机上配提供商是低频操作。
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'pull_to_refresh.dart';

class ModelProvidersPage extends StatefulWidget {
  final AppController app;
  const ModelProvidersPage({super.key, required this.app});

  @override
  State<ModelProvidersPage> createState() => _ModelProvidersPageState();
}

class _ModelProvidersPageState extends State<ModelProvidersPage> {
  List<Map<String, Object?>> _providers = const [];

  /// True when `getAll` returned preset-family providers that this page hides
  /// (see [_isPresetProvider]); used to tell the two empty states apart.
  bool _hasHiddenPresets = false;
  bool _loading = true;
  String? _error;

  /// Preset-family providers (`builtin:*` — Z.ai/BigModel and their Coding
  /// Plan variants) are managed on the desktop: login / OAuth / subscription
  /// flows live there, and the desktop settings page refuses to delete them.
  /// Its "custom" group is exactly `getAll()` minus these, so mirror that.
  bool _isPresetProvider(String? id) => id?.startsWith('builtin:') == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final service = widget.app.modelProviderService;
    if (service == null) {
      setState(() {
        _loading = false;
        _error = '未连接桌面端';
      });
      return;
    }
    try {
      final providers = await service.getAll();
      if (mounted) {
        setState(() {
          final custom = providers
              .where((p) => !_isPresetProvider(p['id']?.toString()))
              .toList();
          _providers = custom;
          _hasHiddenPresets = providers.length != custom.length;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _toggle(Map<String, Object?> provider, bool enabled) async {
    final service = widget.app.modelProviderService;
    if (service == null) return;
    try {
      await service.save({...provider, 'enabled': enabled});
      widget.app.invalidateWorkspaceModelConfig();
      if (!enabled) {
        // Drafts referencing the disabled provider fall back to the workspace
        // default so the next created session can't pick a dead model.
        await _clearDraftsFor(provider['id']?.toString());
      }
      await _load();
    } catch (e) {
      _toast('切换失败：$e');
    }
  }

  Future<void> _clearDraftsFor(String? providerId) async {
    if (providerId == null || providerId.isEmpty) return;
    try {
      for (final prefs in await widget.app.db.listWorkspaceModelPrefs()) {
        if (prefs.provider == providerId) {
          await widget.app.clearWorkspaceModelPrefs(prefs.workspaceKey);
        }
      }
    } catch (_) {
      // Draft cleanup is best-effort; the provider itself was disabled.
    }
  }

  /// "In use" = a local new-session draft or the active workspace's current
  /// model references this provider. (Per-session historical models are a
  /// desktop-side fact the workspace-list payload does not carry.)
  Future<String?> _inUseReason(Map<String, Object?> provider) async {
    final id = provider['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    try {
      final prefs = await widget.app.db.listWorkspaceModelPrefs();
      if (prefs.any((p) => p.provider == id)) {
        return '有工作区的新会话草稿正在使用该提供商';
      }
    } catch (_) {}
    try {
      final config = await widget.app.fetchWorkspaceModelConfig();
      if (config.provider == id) {
        return '当前工作区的默认模型正在使用该提供商';
      }
    } catch (_) {}
    return null;
  }

  Future<void> _delete(Map<String, Object?> provider) async {
    final name =
        provider['name']?.toString() ?? provider['id']?.toString() ?? '';
    // Deleting an in-use provider is refused outright (disabling stays
    // possible — it just falls back the drafts).
    final inUse = await _inUseReason(provider);
    if (!mounted) return;
    if (inUse != null) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法删除'),
          content: Text('「$name」正在使用中：$inUse。请先切换相关会话/草稿到其他模型。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除模型提供商'),
        content: Text('确定要删除「$name」吗？'),
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
    final service = widget.app.modelProviderService;
    if (service == null) return;
    try {
      await service.delete(provider['id']?.toString() ?? '');
      widget.app.invalidateWorkspaceModelConfig();
      await _load();
      _toast('已删除');
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  Future<void> _showAddSheet() async {
    final added = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _AddProviderSheet(),
    );
    if (added == null) return;
    final service = widget.app.modelProviderService;
    if (service == null) return;
    try {
      await service.save(added);
      widget.app.invalidateWorkspaceModelConfig();
      await _load();
      _toast('已添加提供商');
    } catch (e) {
      _toast('添加失败：$e');
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('模型提供商')),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _showAddSheet,
              icon: const Icon(Icons.add),
              label: const Text('添加提供商'),
            ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return RefreshIndicator(
        onRefresh: _load,
        child: RefreshableEmptyState(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_providers.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: RefreshableEmptyState(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _hasHiddenPresets
                  ? '内置预设供应商（Z.ai、BigModel 等）由桌面端管理，这里只显示自定义提供商'
                  : '还没有配置模型提供商',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _providers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final provider = _providers[i];
                final name = provider['name']?.toString() ?? '未命名';
                final type = provider['type']?.toString();
                final baseUrl = provider['baseUrl']?.toString();
                final enabled = provider['enabled'] != false;
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(name.isEmpty ? '?' : name.characters.first),
                    ),
                    title: Text(name),
                    subtitle: Text(
                      [type, baseUrl]
                          .whereType<String>()
                          .where((s) => s.isNotEmpty)
                          .join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: enabled,
                          onChanged: (v) => _toggle(provider, v),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'delete') _delete(provider);
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                leading: Icon(Icons.delete_outline),
                                title: Text('删除'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (_hasHiddenPresets)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
            child: Text(
              '内置预设（Z.ai、BigModel 等）由桌面端管理，不在此列出',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// 添加提供商表单：名称 / 接口类型 / Base URL / API Key / 模型 ID 列表。
/// Phone-side strict validation for the add-provider form. Returns the error
/// message, or null when the payload is clean.
String? validateProviderForm({
  required String name,
  required String baseUrl,
  required List<String> modelIds,
}) {
  if (name.trim().isEmpty) return '请填写名称';
  final url = baseUrl.trim();
  if (url.isNotEmpty) {
    final uri = Uri.tryParse(url);
    final ok =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!ok) return 'Base URL 需是合法的 http(s) 地址';
  }
  if (modelIds.isEmpty) return '至少填写一个模型 ID';
  return null;
}

class _AddProviderSheet extends StatefulWidget {
  const _AddProviderSheet();

  @override
  State<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<_AddProviderSheet> {
  static const _types = [
    'anthropic-messages',
    'openai-chat',
    'gemini',
    'custom',
  ];

  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _modelIds = TextEditingController();
  String _type = _types.first;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _modelIds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加模型提供商', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如 MyOpenAI',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: '接口类型',
                isDense: true,
              ),
              items: [
                for (final t in _types)
                  DropdownMenuItem(value: t, child: Text(t)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _type = v);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                labelText: 'Base URL（可选）',
                hintText: 'https://api.example.com/v1',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _modelIds,
              decoration: const InputDecoration(
                labelText: '模型 ID（逗号分隔）',
                hintText: 'gpt-4o, gpt-4o-mini',
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: _submit, child: const Text('添加')),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final modelIds = _modelIds.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final error = validateProviderForm(
      name: _name.text,
      baseUrl: _baseUrl.text,
      modelIds: modelIds,
    );
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final baseUrl = _baseUrl.text.trim();
    Navigator.of(context).pop(<String, Object?>{
      'name': _name.text.trim(),
      'type': _type,
      if (baseUrl.isNotEmpty) 'baseUrl': baseUrl,
      if (_apiKey.text.trim().isNotEmpty) 'apiKey': _apiKey.text.trim(),
      'modelIds': modelIds,
      'enabled': true,
    });
  }
}
