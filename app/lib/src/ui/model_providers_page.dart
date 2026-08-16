/// 模型提供商管理（model-provider 通道）：列表 / 启停 / 删除 / 添加。
/// 入口在设备页的二级菜单里——手机上配提供商是低频操作。
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';

class ModelProvidersPage extends StatefulWidget {
  final AppController app;
  const ModelProvidersPage({super.key, required this.app});

  @override
  State<ModelProvidersPage> createState() => _ModelProvidersPageState();
}

class _ModelProvidersPageState extends State<ModelProvidersPage> {
  List<Map<String, Object?>> _providers = const [];
  bool _loading = true;
  String? _error;

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
          _providers = providers;
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
      await _load();
    } catch (e) {
      _toast('切换失败：$e');
    }
  }

  Future<void> _delete(Map<String, Object?> provider) async {
    final name = provider['name']?.toString() ?? provider['id']?.toString() ?? '';
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
      await _load();
      _toast('已添加提供商');
    } catch (e) {
      _toast('添加失败：$e');
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_providers.isEmpty) {
      return const Center(child: Text('还没有配置模型提供商'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
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
              [type, baseUrl].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
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
    );
  }
}

/// 添加提供商表单：名称 / 接口类型 / Base URL / API Key / 模型 ID 列表。
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
              child: FilledButton(
                onPressed: _submit,
                child: const Text('添加'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写名称')));
      return;
    }
    final modelIds = _modelIds.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    Navigator.of(context).pop(<String, Object?>{
      'name': name,
      'type': _type,
      if (_baseUrl.text.trim().isNotEmpty) 'baseUrl': _baseUrl.text.trim(),
      if (_apiKey.text.trim().isNotEmpty) 'apiKey': _apiKey.text.trim(),
      if (modelIds.isNotEmpty) 'modelIds': modelIds,
      'enabled': true,
    });
  }
}
