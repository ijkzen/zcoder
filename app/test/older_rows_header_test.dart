import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/ui/conversation_page.dart';

void main() {
  group('OlderRowsHeader (older-rows loading feedback)', () {
    testWidgets('loading shows spinner + hint above the oldest row',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OlderRowsHeader(loading: true, reachedEnd: false),
        ),
      ));
      expect(find.text('正在加载更早记录…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('end of history shows the marker, no spinner', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OlderRowsHeader(loading: false, reachedEnd: true),
        ),
      ));
      expect(find.text('已加载全部历史记录'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('idle (not loading, not exhausted) renders nothing',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OlderRowsHeader(loading: false, reachedEnd: false),
        ),
      ));
      expect(find.text('正在加载更早记录…'), findsNothing);
      expect(find.text('已加载全部历史记录'), findsNothing);
    });
  });
}
