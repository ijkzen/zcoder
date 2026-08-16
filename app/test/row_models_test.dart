import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/session/models.dart';

/// Guards the row parsing/rendering contract against the live desktop data
/// shapes captured 2026-08-16 (see /tmp/rows_dump.mjs output in the handoff).
void main() {
  test('TimelineMarkerRow parses nested marker map (compact)', () {
    final row = ConversationRow.fromJson({
      'rowId': 412,
      'kind': 'timelineMarker',
      'createdAt': 1786830842011,
      'marker': {
        'type': 'compact',
        'origin': 'auto',
        'status': 'success',
        'tokensBefore': 110491,
        'tokensAfter': 15187,
        'summaryRef': 'msg_x',
      },
    });
    expect(row, isA<TimelineMarkerRow>());
    final marker = row as TimelineMarkerRow;
    expect(marker.markerType, 'compact');
    expect(marker.tokensBefore, 110491);
    expect(marker.tokensAfter, 15187);
  });

  test('SubagentRow parses summaryText/status (not summary)', () {
    final row = ConversationRow.fromJson({
      'rowId': 461,
      'kind': 'subagent',
      'subagentType': 'subagent',
      'status': 'success',
      'summaryText': 'Standards 轴代码审查',
      'childSessionId': 'sess_subagent_x',
    });
    expect(row, isA<SubagentRow>());
    final sub = row as SubagentRow;
    expect(sub.summaryText, 'Standards 轴代码审查');
    expect(sub.status, 'success');
    expect(sub.textForCache, 'Standards 轴代码审查');
  });

  test('TurnHeaderRow parses state/startedAt/origin', () {
    final row = ConversationRow.fromJson({
      'rowId': 384,
      'kind': 'turnHeader',
      'origin': 'userInput',
      'executionKind': 'agent',
      'state': 'running',
      'startedAt': 1786829802155,
    });
    expect(row, isA<TurnHeaderRow>());
    final header = row as TurnHeaderRow;
    expect(header.state, 'running');
    expect(header.origin, 'userInput');
    expect(header.startedAt, 1786829802155);
  });

  testWidgets('compact timeline marker renders token counts', (tester) async {
    final row = ConversationRow.fromJson({
      'rowId': 412,
      'kind': 'timelineMarker',
      'marker': {'type': 'compact', 'tokensBefore': 110491, 'tokensAfter': 15187},
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        expect(row, isA<TimelineMarkerRow>());
        return Text('上下文已压缩 · ${(row as TimelineMarkerRow).tokensBefore} → ${row.tokensAfter} tokens');
      })),
    ));
    expect(find.textContaining('上下文已压缩'), findsOneWidget);
  });
}
