/// 协议日志页：最近 1000 条 relay / rpc-frame / V4 帧日志（环形缓冲）。
/// 入口在设备页的二级菜单——排查连接问题的工具页，平时用不到。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/zlog.dart';

class ProtocolLogPage extends StatefulWidget {
  const ProtocolLogPage({super.key});

  @override
  State<ProtocolLogPage> createState() => _ProtocolLogPageState();
}

class _ProtocolLogPageState extends State<ProtocolLogPage> {
  final _controller = ScrollController();
  StreamSubscription<LogEntry>? _sub;
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // Live tail: new lines keep the view pinned to the bottom while the user
    // hasn't scrolled up.
    _sub = ProtocolLog.instance.stream.listen((_) {
      if (_atBottom && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_controller.hasClients) {
            _controller.jumpTo(0);
          }
        });
      }
      if (mounted) setState(() {});
    });
  }

  void _onScroll() {
    final position = _controller.position;
    final atBottom = position.pixels <= 120;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = ProtocolLog.instance.entries
        .map((e) =>
            '${e.at.toIso8601String().substring(11, 23)} ${e.message}')
        .join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制日志')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = ProtocolLog.instance.entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('协议日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            onPressed: _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: () => setState(ProtocolLog.instance.clear),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                '暂无协议日志',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              controller: _controller,
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                // reverse: index 0 is the newest.
                final entry = entries[entries.length - 1 - i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SelectableText(
                    '${entry.at.toIso8601String().substring(11, 23)}  ${entry.message}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                  ),
                );
              },
            ),
    );
  }
}
