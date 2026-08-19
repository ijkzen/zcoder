/// 设置页：应用更新检查与安装。
/// 入口在设备页的二级菜单里——检查 GitHub Releases 是否有比当前
/// 版本更高的发布，支持下载加速源切换和正式版/预发布渠道切换。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';

import '../services/app_version.dart';
import '../services/battery_optimization.dart';
import '../services/update_checker.dart';
import '../storage/app_database.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  UpdateChannel _channel = UpdateChannel.stable;
  UpdateMirror _mirror = UpdateMirror.auto;
  bool _loading = false;
  bool _checking = false;
  String? _checkError;
  String? _noUpdateMsg;

  /// 本机实际安装版本（从安卓包 versionName 动态读取，见 app_version.dart）。
  String? _appVersion;

  /// 电池优化豁免状态（null = 加载中）。
  bool? _batteryExempt;

  /// 设备厂商（null = 加载中）。
  String? _manufacturer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    currentAppVersion().then((version) {
      if (mounted) setState(() => _appVersion = version);
    });
    isIgnoringBatteryOptimizations().then((exempt) {
      if (mounted) setState(() => _batteryExempt = exempt);
    });
    deviceManufacturer().then((m) {
      if (mounted) setState(() => _manufacturer = m);
    });
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

    final version = await currentAppVersion();
    if (version == null) {
      if (mounted) {
        setState(() {
          _checking = false;
          _checkError = '无法读取当前应用版本';
        });
      }
      return;
    }

    try {
      final checker = UpdateChecker(
        owner: 'ijkzen',
        repo: 'zcoder',
        currentVersion: version,
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
            // ---------- 后台保活 ----------
            _SectionHeader(title: '后台保活'),
            ListTile(
              leading: const Icon(Icons.battery_saver),
              title: const Text('电池优化'),
              trailing: Text(
                _batteryExempt == null
                    ? '检测中…'
                    : (_batteryExempt! ? '已优化 ✓' : '未优化 ⚠'),
                style: TextStyle(
                  color: _batteryExempt == null
                      ? null
                      : (_batteryExempt! ? scheme.primary : scheme.error),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('厂商适配指南'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _BatteryGuideDialog(
                  manufacturer: _manufacturer,
                ),
              ),
            ),
            const Divider(height: 32),
            // ---------- 更新检查 ----------
            _SectionHeader(title: '应用更新'),
            ListTile(
              leading: const Icon(Icons.system_update),
              title: const Text('当前版本'),
              trailing: Text(
                _appVersion == null ? '读取中…' : 'v$_appVersion',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
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
                items: [
                  for (final m in UpdateMirror.values)
                    DropdownMenuItem(value: m, child: Text(m.displayName)),
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

  /// The accelerator (or 官方直连) the current attempt is downloading from.
  String? _source;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    final checker = UpdateChecker(
      owner: 'ijkzen',
      repo: 'zcoder',
      // 仅用于下载请求的 User-Agent；读取失败回退空串即可。
      currentVersion: (await currentAppVersion()) ?? '',
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
        onSource: (source) {
          if (mounted) setState(() => _source = source);
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

  void _retry() {
    setState(() {
      _error = null;
      _progress = 0;
      _received = 0;
      _source = null;
    });
    _startDownload();
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
            Row(
              children: [
                FilledButton(
                  onPressed: _retry,
                  child: const Text('重试'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
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
            if (_source != null) ...[
              const SizedBox(height: 6),
              Text(
                '下载来源：$_source',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
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

/// Dialog showing device-specific battery optimization guide.
class _BatteryGuideDialog extends StatelessWidget {
  final String? manufacturer;
  const _BatteryGuideDialog({this.manufacturer});

  @override
  Widget build(BuildContext context) {
    final steps = _stepsFor(manufacturer);
    return AlertDialog(
      title: const Text('后台保活设置'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '厂商: ${manufacturer ?? "未知"}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < steps.length; i++) ...[
                Text('${i + 1}. ${steps[i]}'),
                if (i < steps.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            openBatteryOptimizationSettings();
          },
          icon: const Icon(Icons.open_in_new),
          label: const Text('打开应用设置'),
        ),
      ],
    );
  }

  List<String> _stepsFor(String? m) {
    if (m == 'xiaomi' || m == 'redmi') {
      return [
        '打开手机「设置」→「应用设置」→「应用管理」',
        '搜索或找到「ZCode 远程」并点击进入',
        '点击「省电策略」→ 选择「无限制」',
        '返回，找到「自启动」→ 开启',
        '返回，找到「后台运行」→ 开启',
      ];
    }
    if (m == 'huawei' || m == 'honor') {
      return [
        '打开手机「设置」→「应用和服务」→「应用管理」',
        '找到「ZCode 远程」→「耗电详情」',
        '关闭「应用启动管理」的自动管理，改为手动管理：开启「自启动」「关联启动」「后台活动」',
        '返回，点击「电池」→ 选择「不受限制」',
      ];
    }
    if (m == 'oppo' || m == 'oneplus' || m == 'realme') {
      return [
        '打开手机「设置」→「应用管理」→「应用列表」',
        '找到「ZCode 远程」→「耗电管理」→ 选择「允许后台运行」',
        '返回，点击「省电优化」→ 选择「不优化」',
        '打开「手机管家」→「自启动管理」→ 开启「ZCode 远程」',
      ];
    }
    if (m == 'vivo' || m == 'iqoo') {
      return [
        '打开手机「设置」→「应用与权限」→「应用管理」',
        '找到「ZCode 远程」→「省电策略」→ 选择「无限制」',
        '返回，点击「权限管理」→「自启动」→ 开启',
      ];
    }
    if (m == 'samsung') {
      return [
        '打开手机「设置」→「电池和设备维护」→「电池」',
        '点击「后台使用限制」→ 将「ZCode 远程」从「深度优化」列表移除',
        '或：「设置」→「应用」→「ZCode 远程」→「电池」→ 选择「不受限制」',
      ];
    }
    // Generic fallback.
    return [
      '打开手机「设置」→「应用管理」→ 找到「ZCode 迩程」',
      '找到「电池」或「省电」相关选项',
      '将优化策略改为「不受限制」或「无限制」',
      '如有机型专属的「自启动」「后台运行」开关，请一并开启',
    ];
  }
}
