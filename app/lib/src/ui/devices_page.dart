import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import '../storage/app_database.dart';
import 'deep_link.dart';
import 'scan_page.dart';
import 'workspaces_page.dart';
import 'model_providers_page.dart';
import 'log_page.dart';
import 'settings_page.dart';

/// Screen 1: the paired devices list. Scan a QR to add a device, tap a device
/// to connect, long-press to rename, swipe to remove.
class DevicesPage extends StatefulWidget {
  final AppController app;
  const DevicesPage({super.key, required this.app});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _scanning = false;
  bool _connecting = false;

  /// Incremented on every connect attempt; a superseded attempt (the user
  /// tapped another device mid-connect) must not report failures or clear the
  /// spinner of the attempt that replaced it.
  int _connectGen = 0;

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final raw = await Navigator.of(
        context,
      ).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
      if (raw == null || raw.isEmpty || !mounted) return;
      await _pairFromUrl(raw);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pairFromUrl(String url) async {
    try {
      final result = await widget.app.addPairingFromUrl(url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.alreadyExisted
                  ? '该设备已配对过：${result.pairing.displayName}'
                  : '已配对：${result.pairing.displayName}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('配对失败：$e')));
      }
    }
  }

  Future<void> _pasteLink() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴远程控制链接'),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://zcode.z.ai/remote/v4?...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('配对'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    await _pairFromUrl(url.trim());
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor:
                        Theme.of(dialogContext).colorScheme.errorContainer,
                    foregroundColor:
                        Theme.of(dialogContext).colorScheme.onErrorContainer,
                  )
                : null,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _connect(StoredPairing pairing) async {
    // Tapping the already-connected device skips the reconnect entirely.
    final isActive =
        widget.app.activePairing?.id == pairing.id &&
        widget.app.phase != BridgePhase.idle &&
        widget.app.phase != BridgePhase.failed;
    if (isActive) {
      // `pairing` (relay paired, no workspace picked) and `ready` (bridge
      // open) both have the project list loaded — re-enter it instead of
      // reconnecting. Returning from the project list without picking a
      // workspace leaves the bridge in `pairing`, so tapping must reopen
      // the list rather than no-op.
      if (widget.app.phase == BridgePhase.pairing ||
          widget.app.phase == BridgePhase.ready) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WorkspacesPage(app: widget.app)),
        );
      }
      return;
    }
    final gen = ++_connectGen;
    setState(() => _connecting = true);
    try {
      await widget.app.connectTo(pairing);
      // Wait for the pairing to complete (workspace list available). The
      // bridge only reaches `ready` after the user picks a workspace.
      final bridge = widget.app.bridge;
      if (bridge == null) return;
      final completer = Completer<void>();
      late final StreamSubscription<BridgePhase> sub;
      sub = bridge.phaseStream.listen((p) {
        if (p == BridgePhase.pairing && !completer.isCompleted) {
          completer.complete();
        }
        if (p == BridgePhase.failed && !completer.isCompleted) {
          completer.completeError(StateError(widget.app.lastError ?? '连接失败'));
        }
      });
      try {
        await completer.future.timeout(const Duration(seconds: 30));
      } finally {
        await sub.cancel();
      }
      if (!mounted || gen != _connectGen) return;
      // A notification tap may have asked us to open a specific session —
      // jump straight to it instead of the workspace list.
      final deepLink = widget.app.consumePendingDeepLink();
      if (deepLink != null) {
        await handleDeepLink(widget.app, '${deepLink.$1}|${deepLink.$2}');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => WorkspacesPage(app: widget.app)),
      );
    } catch (e) {
      // A failed connect must not leave a stale deep link behind — it would
      // otherwise fire on some later unrelated successful connect.
      widget.app.discardPendingDeepLink();
      if (mounted && gen == _connectGen) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('连接失败：$e')));
      }
    } finally {
      if (mounted && gen == _connectGen) setState(() => _connecting = false);
    }
  }

  Future<void> _rename(StoredPairing pairing) async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _RenameDeviceDialog(initialName: pairing.displayName),
    );
    if (name != null && name.trim().isNotEmpty) {
      await widget.app.renamePairing(pairing, name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZCode 远程'),
        actions: [
          IconButton(
            tooltip: '粘贴链接',
            icon: const Icon(Icons.link),
            onPressed: _pasteLink,
          ),
          if (_connecting)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          // 低频入口统一收在二级菜单：模型提供商管理、协议日志。
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              switch (value) {
                case 'providers':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ModelProvidersPage(app: widget.app),
                    ),
                  );
              case 'logs':
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProtocolLogPage()),
                );
              case 'settings':
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'providers',
                child: ListTile(
                  leading: Icon(Icons.dns_outlined),
                  title: Text('模型提供商'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'logs',
                child: ListTile(
                  leading: Icon(Icons.terminal),
                  title: Text('协议日志'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('设置'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _scan,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('扫码配对'),
      ),
      body: ListenableBuilder(
        listenable: widget.app,
        builder: (context, _) {
          if (widget.app.pairings.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            itemCount: widget.app.pairings.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final pairing = widget.app.pairings[i];
              final isActive =
                  widget.app.activePairing?.id == pairing.id &&
                  widget.app.phase != BridgePhase.idle;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isActive
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.computer,
                      color: isActive
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: Text(pairing.displayName),
                  subtitle: Text(
                    isActive
                        ? _phaseLabel(widget.app.phase)
                        : pairing.deviceName ?? pairing.deviceSid,
                    style: TextStyle(
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () => _connect(pairing),
                  onLongPress: () => _rename(pairing),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'delete') {
                        if (!await _confirm(
                              title: '删除配对',
                              message: '确定删除「${pairing.displayName}」的配对吗？删除后需重新扫码配对才能连接。',
                              confirmLabel: '删除',
                              destructive: true,
                            )) {
                          return;
                        }
                        await widget.app.removePairing(pairing);
                      } else if (v == 'rename') {
                        await _rename(pairing);
                      } else if (v == 'disconnect') {
                        if (!await _confirm(
                              title: '断开连接',
                              message: '确定断开与「${pairing.displayName}」的连接吗？可随时重新点击设备恢复连接。',
                              confirmLabel: '断开',
                              destructive: true,
                            )) {
                          return;
                        }
                        await widget.app.disconnect();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('重命名'),
                      ),
                      if (isActive)
                        const PopupMenuItem(
                          value: 'disconnect',
                          child: Text('断开连接'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除配对'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _phaseLabel(BridgePhase phase) {
    switch (phase) {
      case BridgePhase.connecting:
        return '连接中…';
      case BridgePhase.pairing:
        // relay 已配对、项目列表已加载，只是还没开 bridge 进会话。
        // 这个 label 用户只在从项目列表返回后看到——桌面端早已响应，
        // 显示"已连接"才符合实际状态。
        return '已连接';
      case BridgePhase.ready:
        return '已连接';
      case BridgePhase.reconnecting:
        return '重连中…';
      case BridgePhase.failed:
        return '连接失败';
      case BridgePhase.idle:
        return '未连接';
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.qr_code_2, size: 72, color: scheme.outline),
          const SizedBox(height: 16),
          Text('还没有配对的设备', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '在桌面端 ZCode 打开「Web 远程控制」\n然后用手机扫描二维码',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Rename dialog that refuses blank names by keeping 保存 disabled (owns its
/// controller in State so disposal happens after the TextField unmounts).
class _RenameDeviceDialog extends StatefulWidget {
  final String initialName;
  const _RenameDeviceDialog({required this.initialName});

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名设备'),
      content: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          final blank = value.text.trim().isEmpty;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: '设备名称'),
                onSubmitted: (_) {
                  if (!blank) Navigator.of(context).pop(_controller.text);
                },
              ),
              if (blank) ...[
                const SizedBox(height: 6),
                Text(
                  '名称不能为空',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(_controller.text),
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }
}
