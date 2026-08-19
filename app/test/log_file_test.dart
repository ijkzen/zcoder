import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/log_file.dart';

void main() {
  group('AppLogFile.fileNameFor', () {
    test('日期格式化 zremote_yyyy-MM-dd.log', () {
      expect(AppLogFile.fileNameFor(DateTime(2026, 8, 19)), 'zremote_2026-08-19.log');
      expect(AppLogFile.fileNameFor(DateTime(2026, 1, 2)), 'zremote_2026-01-02.log');
    });
  });

  group('AppLogFile.isStale', () {
    test('早于保留窗口的日志判为过期，窗口内保留', () {
      final now = DateTime(2026, 8, 19);
      // 今天、以及正好 7 天前（8-12）的文件都在窗口内。
      expect(AppLogFile.isStale('zremote_2026-08-19.log', now, 7), isFalse);
      expect(AppLogFile.isStale('zremote_2026-08-12.log', now, 7), isFalse);
      // 8-11 更早，超出 7 天窗口。
      expect(AppLogFile.isStale('zremote_2026-08-11.log', now, 7), isTrue);
    });

    test('非日志文件不误判', () {
      final now = DateTime(2026, 8, 19);
      expect(AppLogFile.isStale('pairings.txt', now, 7), isFalse);
      expect(AppLogFile.isStale('zremote.log', now, 7), isFalse);
    });
  });

  group('AppLogFile 落盘', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('zremote_log_test_');
    });

    tearDown(() async {
      await AppLogFile.instance.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('按天写文件：含时间戳与启动头', () async {
      AppLogFile.instance.now = () => DateTime(2026, 8, 19, 10, 30, 5, 123);
      await AppLogFile.instance.init(
        overrideDir: tempDir.path,
        header: '== 启动 v0.4.22 / Pixel 7 ==',
      );
      AppLogFile.instance.writeLine('hello file log');
      await AppLogFile.instance.flush();

      final file = File('${tempDir.path}/zremote_2026-08-19.log');
      expect(file.existsSync(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('== 启动 v0.4.22 / Pixel 7 =='));
      expect(content, contains('2026-08-19 10:30:05.123  hello file log'));
    });

    test('跨天滚动到新文件且保留旧文件', () async {
      var day = DateTime(2026, 8, 19, 9);
      AppLogFile.instance.now = () => day;
      await AppLogFile.instance.init(overrideDir: tempDir.path);

      AppLogFile.instance.writeLine('day1 line');
      // 前进一天：flush 时滚动出当日新文件。
      day = DateTime(2026, 8, 20, 9);
      await AppLogFile.instance.flush();
      AppLogFile.instance.writeLine('day2 line');
      await AppLogFile.instance.flush();

      final day1 = File('${tempDir.path}/zremote_2026-08-19.log');
      final day2 = File('${tempDir.path}/zremote_2026-08-20.log');
      expect(day1.existsSync(), isTrue);
      expect(day2.existsSync(), isTrue);
      expect(await day1.readAsString(), contains('day1 line'));
      expect(await day2.readAsString(), contains('day2 line'));
    });

    test('启动时清理超过保留天数的旧日志', () async {
      AppLogFile.instance.now = () => DateTime(2026, 8, 19);
      // 预置一个过期的和一个在窗口内的文件。
      File('${tempDir.path}/zremote_2026-08-01.log').writeAsStringSync('old');
      File('${tempDir.path}/zremote_2026-08-15.log').writeAsStringSync('keep');

      await AppLogFile.instance.init(overrideDir: tempDir.path);
      await AppLogFile.instance.flush();

      expect(
        File('${tempDir.path}/zremote_2026-08-01.log').existsSync(),
        isFalse,
        reason: '超过 7 天的日志文件应被清理',
      );
      expect(
        File('${tempDir.path}/zremote_2026-08-15.log').existsSync(),
        isTrue,
      );
    });
  });
}
