/// 设置页：应用更新检查与安装。
/// 入口在设备页的二级菜单里——检查 GitHub Releases 是否有比当前
/// 版本更高的发布，支持下载加速源切换和正式版/预发布渠道切换。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';

import '../services/update_checker.dart';
import '../storage/app_database.dart';

/// App version from pubspec — kept in sync manually with pubspec.yaml.
const appVersion = '0.4.4';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  UpdateChannel _channel = UpdateChannel.stable;
  UpdateMirror _mirror = UpdateMirror.official;
  bool _loading = false;
  bool _checking = false;
  String? _checkError;
  String? _noUpdateMsg;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _loading = true);
    final db = AppDatabase.instance;
    final channelLabel = await db.getSetting('update_channel');
    final mirrorLabel = await db.getSetting('update_mirror');
    if (mounted) {
      setState(() {
        _channel = UpdateChannel.fromLabel(channelLabel);
        _mirror = UpdateMirror.fromLabel(mirrorLabel);
        _loading = false;
      });
    }
  }

  Future<void> _changeChannel(UpdateChannel channel) async {
    setState(() => _channel = channel);
    await AppDatabase.instance.setSetting('update_channel', channel.label);
  }

  Future<void> _changeMirror(UpdateMirror mirror) async {
    setState(() => _mirror = mirror);
    await AppDatabase.instance.setSetting('update_mirror', mirror.label);
  }

  Future<void> _checkForUpdate() async {
    setState(() {
      _checking = true;
      _checkError = null;
      _noUpdateMsg = null;
    });

    try {
      final checker = UpdateChecker(
        owner: 'ijkzen',
        repo: 'zcoder',
        currentVersion: appVersion,
      );
      final info = await checker.checkForUpdate(channel: _channel);
      if (mounted) {
        setState(() {
          _checking = false;
          if (info == null) {
            _noUpdateMsg = '已是最新版本';
          }
        });
        if (info != null) {
          final shouldUpdate = await showDialog<bool>(
            context: context,
            builder: (_) => _UpdateAvailableDialog(info: info),
          );
          if (shouldUpdate == true && mounted) {
            _showDownloadDialog(info);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _checkError = '$e';
        });
      }
    }
  }

  void _showDownloadDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadProgressDialog(
        info: info,
        mirror: _mirror,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            // ---------- 更新检查 ----------
            _SectionHeader(title: '应用更新'),
            ListTile(
              leading: const Icon(Icons.system_update),
              title: const Text('当前版本'),
              trailing: Text('v$appVersion',
                  style: Theme.of(context).textTheme.bodyLarge),
            ),
            ListTile(
              leading: const Icon(Icons.rss_feed),
              title: const Text('更新渠道'),
              trailing: DropdownButton<UpdateChannel>(
                value: _channel,
                onChanged: (v) {
                  if (v != null) _changeChannel(v);
                },
                items: const [
                  DropdownMenuItem(
                    value: UpdateChannel.stable,
                    child: Text('正式版'),
                  ),
                  DropdownMenuItem(
                    value: UpdateChannel.nightly,
                    child: Text('含预发布 (nightly)'),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载加速源'),
              trailing: DropdownButton<UpdateMirror>(
                value: _mirror,
                onChanged: (v) {
                  if (v != null) _changeMirror(v);
                },
                items: const [
                  DropdownMenuItem(
                    value: UpdateMirror.official,
                    child: Text('官方直连'),
                  ),
                  DropdownMenuItem(
                    value: UpdateMirror.ghproxy,
                    child: Text('GH Proxy'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                onPressed: _checking ? null : _checkForUpdate,
                icon: _checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(_checking ? '检查中…' : '检查更新'),
              ),
            ),
            if (_checkError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _checkError!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            if (_noUpdateMsg != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _noUpdateMsg!,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            const Divider(height: 32),
          ],
        ],
      ),
    );
  }

}

String _formatDate(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

/// Dialog showing update release notes with "取消" and "更新" buttons.
/// Returns true when the user taps "更新"; false (or null via barrier
/// dismiss) when they cancel — the caller uses this to decide whether to
/// proceed with the download/install flow.
class _UpdateAvailableDialog extends StatelessWidget {
  final UpdateInfo info;

  const _UpdateAvailableDialog({required this.info});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('发现新版本 ${info.displayVersion}'),
          ),
          if (info.isPrerelease)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '预发布',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '发布时间: ${_formatDate(info.publishedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (info.releaseNotes != null && info.releaseNotes!.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: info.releaseNotes!,
                    selectable: true,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.download),
          label: const Text('更新'),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
            ),
      ),
    );
  }
}

/// Download progress dialog with a linear progress bar.
class _DownloadProgressDialog extends StatefulWidget {
  final UpdateInfo info;
  final UpdateMirror mirror;

  const _DownloadProgressDialog({
    required this.info,
    required this.mirror,
  });

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  double _progress = 0;
  int _received = 0;
  bool _installing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    final checker = UpdateChecker(
      owner: 'ijkzen',
      repo: 'zcoder',
      currentVersion: appVersion,
    );

    try {
      final path = await checker.downloadApk(
        widget.info.asset,
        mirror: widget.mirror,
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
              _received = (p * widget.info.asset.size).round();
            });
          }
        },
      );

      if (!mounted) return;
      setState(() {
        _installing = true;
      });

      // Hand off to the system installer.
      final result = await OpenFilex.open(path);
      if (mounted) {
        if (result.type != ResultType.done) {
          setState(() {
            _installing = false;
            _error = '无法打开安装界面: ${result.message}';
          });
        } else {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_installing ? '正在安装…' : '下载更新'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ] else if (_installing) ...[
            const Text('已下载完成，请在系统弹窗中完成安装。'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ] else ...[
            Text(
              '${widget.info.displayVersion} · ${widget.info.asset.name}',
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(
              '${(_progress * 100).toStringAsFixed(0)}%  ·  '
              '${_formatBytes(_received)} / ${_formatBytes(widget.info.asset.size)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
