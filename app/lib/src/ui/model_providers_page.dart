/// 模型提供商管理（model-provider 通道）：列表 / 启停 / 删除。
/// 入口在设备页的二级菜单里。供应商统一在桌面端添加/编辑，手机端不提供
/// 添加入口（桌面端 API 格式与端点路由已演进到 v2 存储格式，单独在手机端
/// 对齐成本较高且属低频操作）。
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
