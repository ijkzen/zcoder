import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import '../storage/app_database.dart';
import 'conversation_page.dart';
import 'scan_page.dart';
import 'workspaces_page.dart';
import 'model_providers_page.dart';
import 'log_page.dart';

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

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ScanPage()),
      );
      if (raw == null || raw.isEmpty || !mounted) return;
      try {
        final pairing = await widget.app.addPairingFromUrl(raw);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已配对：${pairing.displayName}'),
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('配对失败：$e')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pasteLink() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴远程控制链接'),
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
    try {
      final pairing = await widget.app.addPairingFromUrl(url.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已配对：${pairing.displayName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('配对失败：$e')),
        );
      }
    }
  }

  Future<void> _connect(StoredPairing pairing) async {
    setState(() => _connecting = true);
    try {
      await widget.app.connectTo(pairing);
      // Wait for the pairing to complete (workspace list available). The
      // bridge only reaches `ready` after the user picks a workspace.
      final completer = Completer<void>();
      late final StreamSubscription<BridgePhase> sub;
      sub = widget.app.bridge!.phaseStream.listen((p) {
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
      if (!mounted) return;
      // A notification tap may have asked us to open a specific session —
      // jump straight to it instead of the workspace list.
      final deepLink = widget.app.consumePendingDeepLink();
      if (deepLink != null) {
        final (workspaceKey, sessionId) = deepLink;
        final workspace = widget.app.workspaces
            .where((w) => w.workspaceKey == workspaceKey)
            .firstOrNull;
        if (workspace != null) {
          await widget.app.selectWorkspace(workspace);
          if (!mounted || widget.app.phase != BridgePhase.ready) return;
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                ConversationPage(app: widget.app, sessionId: sessionId),
          ));
          return;
        }
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WorkspacesPage(app: widget.app),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _rename(StoredPairing pairing) async {
    final controller = TextEditingController(text: pairing.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '设备名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
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
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ModelProvidersPage(app: widget.app),
                  ));
                case 'logs':
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ProtocolLogPage(),
                  ));
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
            separatorBuilder: (_, __) => const SizedBox(height: 8),
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
                        : '${pairing.deviceName ?? pairing.deviceSid}',
                    style: TextStyle(
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: _connecting ? null : () => _connect(pairing),
                  onLongPress: () => _rename(pairing),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'delete') {
                        await widget.app.removePairing(pairing);
                      } else if (v == 'rename') {
                        await _rename(pairing);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除配对')),
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
        return '等待桌面端…';
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
          Text(
            '还没有配对的设备',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
