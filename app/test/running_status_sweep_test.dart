import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/ui/conversation_page.dart';

ToolCallRow _row(
  String toolName,
  String status, {
  Map<String, Object?>? input,
}) {
  return ToolCallRow(
    rowId: 1,
    toolCallId: 'tc-1',
    toolName: toolName,
    status: status,
    input: input,
    raw: const {},
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
  );
}

/// Plain text of the RichText inside the row's Expanded (the Text.rich holding
/// verb + preview). The sweep label's own Text lives outside the Expanded.
String _lineRichText(WidgetTester tester) {
  final rich = tester.widget<RichText>(
    find.descendant(of: find.byType(Expanded), matching: find.byType(RichText)),
  );
  return rich.text.toPlainText();
}

void main() {
  group('SweepingLabel 左对齐', () {
    testWidgets('first glyph starts exactly at the label left edge',
        (tester) async {
      await tester.pumpWidget(_wrap(const SweepingLabel(text: '正在执行')));
      final labelLeft = tester.getTopLeft(find.byType(SweepingLabel)).dx;
      final glyphLeft = tester.getTopLeft(find.text('正在执行')).dx;
      expect(glyphLeft, labelLeft);
    });

    testWidgets('工作中 / 正在执行 glyph left edges align with each other',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SweepingLabel(text: '工作中'),
            SweepingLabel(text: '正在执行'),
          ],
        ),
      ));
      expect(
        tester.getTopLeft(find.text('工作中')).dx,
        tester.getTopLeft(find.text('正在执行')).dx,
      );
    });
  });

  group('ToolCallLine 运行中状态', () {
    testWidgets('running Bash: sweep label, no spinner, no duplicated verb',
        (tester) async {
      await tester.pumpWidget(_wrap(ToolCallLine(
        row: _row('Bash', 'running', input: {'command': 'ls -la'}),
        onTap: () {},
      )));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在执行'), findsOneWidget);
      expect(_lineRichText(tester), isNot(contains('正在执行')));
      expect(_lineRichText(tester), contains('ls -la'));
    });

    testWidgets('running Read: sweep + tool-name verb kept', (tester) async {
      await tester.pumpWidget(_wrap(ToolCallLine(
        row: _row('Read', 'running', input: {'file_path': '/a/b.dart'}),
        onTap: () {},
      )));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在执行'), findsOneWidget);
      expect(_lineRichText(tester), contains('读取'));
      expect(_lineRichText(tester), contains('/a/b.dart'));
    });

    testWidgets('running Task: sweep + description, 「子代理」verb omitted',
        (tester) async {
      await tester.pumpWidget(_wrap(ToolCallLine(
        row: _row('Task', 'pending', input: {'description': '探索代码库'}),
        onTap: () {},
      )));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在执行'), findsOneWidget);
      expect(_lineRichText(tester), isNot(contains('子代理')));
      expect(_lineRichText(tester), contains('探索代码库'));
    });

    testWidgets('completed Bash: static icon + 已执行, no sweep, no spinner',
        (tester) async {
      await tester.pumpWidget(_wrap(ToolCallLine(
        row: _row('Bash', 'completed', input: {'command': 'ls'}),
        onTap: () {},
      )));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(SweepingLabel), findsNothing);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
      expect(_lineRichText(tester), contains('已执行'));
    });

    testWidgets('failed Bash: red error icon + 执行失败', (tester) async {
      await tester.pumpWidget(_wrap(ToolCallLine(
        row: _row('Bash', 'error', input: {'command': 'ls'}),
        onTap: () {},
      )));
      expect(find.byType(SweepingLabel), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(_lineRichText(tester), contains('执行失败'));
    });
  });
}
