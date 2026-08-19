/// 日志文件落盘：按天一个文件，写到 app 专属外部目录，保留最近 7 天。
///
/// `zlog()` 的每条日志都会追加到 `zremote_yyyy-MM-dd.log`（见 [AppLogFile]），
/// 目录在 Android 上是 `/sdcard/Android/data/<pkg>/files/`——无需存储权限，
/// 且即使装了 release 包也能 `adb pull`，方便脱离日志页持续排查问题。
///
/// 这里的所有 I/O 异常都刻意吞掉：日志不能反过来把 app 弄崩。
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App-wide log file writer：单例、常开一个 append 的 `IOSink`、按天滚动。
class AppLogFile {
  AppLogFile._();
  static final AppLogFile instance = AppLogFile._();

  /// 日志文件保留天数；早于此时长的旧文件在启动/跨天清理。
  static const int retentionDays = 7;
  static const String filePrefix = 'zremote_';

  /// 测试注入点：当前时间来源（默认 [DateTime.now]）。
  DateTime Function() now = DateTime.now;

  Directory? _dir;
  IOSink? _sink;
  String? _fileName;
  String? _header;
  Timer? _flushTimer;

  /// 就绪后开启后台缓冲刷盘（每 5s 一次，含跨天滚动）。
  Future<void> init({String? overrideDir, String? header}) async {
    _header = header;
    try {
      if (overrideDir != null) {
        _dir = Directory(overrideDir);
      } else {
        final external = await getExternalStorageDirectory();
        _dir = external ?? await getApplicationDocumentsDirectory();
      }
      await _dir!.create(recursive: true);
      await _rotateTo(fileNameFor(now()));
      _flushTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(flush()),
      );
    } catch (_) {
      // 目录拿不到/建不了时降级为纯内存日志，绝不能阻塞启动。
      _dir = null;
      _sink = null;
    }
  }

  /// 同步追加一行；格式 `yyyy-MM-dd HH:mm:ss.SSS  message`。
  void writeLine(String message) {
    try {
      final sink = _sink;
      if (sink == null) return;
      // 多行消息（如崩溃堆栈）只给首行加时间戳，续行缩进对齐便于读。
      final indented = message.replaceAll('\n', '\n    ');
      sink.write('${_fmt(now())}  $indented\n');
    } catch (_) {}
  }

  /// 刷新缓冲；跨天时顺带滚动到当日文件并清理过期文件。
  Future<void> flush() async {
    try {
      if (_dir == null) return;
      final today = fileNameFor(now());
      if (_fileName != today) {
        await _rotateTo(today);
      }
      await _sink?.flush();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _closeSink();
    _dir = null;
  }

  Future<void> _rotateTo(String fileName) async {
    await _closeSink();
    _fileName = fileName;
    _sink = _openSink(fileName);
    await _pruneStale();
  }

  IOSink _openSink(String fileName) {
    final file = File('${_dir!.path}/$fileName');
    final sink = file.openWrite(mode: FileMode.append);
    final header = _header;
    if (header != null) {
      sink.write('${_fmt(now())}  $header\n');
    }
    return sink;
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
  }

  Future<void> _pruneStale() async {
    final dir = _dir;
    if (dir == null) return;
    final today = now();
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (isStale(entity.uri.pathSegments.last, today, retentionDays)) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  /// `zremote_2026-08-19.log`
  static String fileNameFor(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    return '$filePrefix$y-${_pad2(d.month)}-${_pad2(d.day)}.log';
  }

  /// 文件名是否已超出保留窗口（日期早于 [now] 往前 [days] 天）。
  static bool isStale(String fileName, DateTime now, int days) {
    if (!fileName.startsWith(filePrefix) || !fileName.endsWith('.log')) {
      return false;
    }
    final datePart = fileName.substring(
      filePrefix.length,
      fileName.length - '.log'.length,
    );
    final date = DateTime.tryParse(datePart);
    if (date == null) return false;
    final cutoff = DateTime(now.year, now.month, now.day - days);
    return date.isBefore(cutoff);
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  static String _pad3(int n) => n.toString().padLeft(3, '0');

  static String _fmt(DateTime d) {
    return '${d.year}-${_pad2(d.month)}-${_pad2(d.day)} '
        '${_pad2(d.hour)}:${_pad2(d.minute)}:${_pad2(d.second)}.'
        '${_pad3(d.millisecond)}';
  }
}
