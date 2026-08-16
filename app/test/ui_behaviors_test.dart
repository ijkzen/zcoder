import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/app_controller.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/ui/model_config_sheet.dart';
import 'package:zcode_remote/src/ui/model_providers_page.dart';

void main() {
  group('extractSessionIdFromResult', () {
    test('direct sessionId', () {
      expect(
        extractSessionIdFromResult({'sessionId': 's1'}),
        's1',
      );
    });

    test('nested under result', () {
      expect(
        extractSessionIdFromResult({
          'status': 'accepted',
          'result': {'sessionId': 's2'},
        }),
        's2',
      );
    });

    test('taskId fallback', () {
      expect(extractSessionIdFromResult({'taskId': 't9'}), 't9');
    });

    test('empty / missing → null', () {
      expect(extractSessionIdFromResult({'sessionId': ''}), isNull);
      expect(extractSessionIdFromResult({'status': 'accepted'}), isNull);
    });
  });

  group('validateProviderForm', () {
    test('name required', () {
      expect(
        validateProviderForm(name: '  ', baseUrl: '', modelIds: ['m']),
        '请填写名称',
      );
    });

    test('baseUrl must be http(s) when filled', () {
      expect(
        validateProviderForm(name: 'n', baseUrl: 'ftp://x', modelIds: ['m']),
        isNotNull,
      );
      expect(
        validateProviderForm(name: 'n', baseUrl: 'not a url', modelIds: ['m']),
        isNotNull,
      );
      expect(
        validateProviderForm(
            name: 'n', baseUrl: 'https://api.example.com/v1', modelIds: ['m']),
        isNull,
      );
      // Empty stays valid (optional field).
      expect(
        validateProviderForm(name: 'n', baseUrl: '', modelIds: ['m']),
        isNull,
      );
    });

    test('at least one model id', () {
      expect(
        validateProviderForm(name: 'n', baseUrl: '', modelIds: const []),
        '至少填写一个模型 ID',
      );
    });
  });

  group('ModelConfigSheet locked (agent running)', () {
    final config = SessionModelConfig(
      availableModels: const [
        ModelOption(
          provider: 'p1',
          providerLabel: 'P1',
          model: 'm1',
          label: 'Model One',
        ),
      ],
    );

    testWidgets('locked sheet shows the banner and refuses taps',
        (tester) async {
      var applied = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ModelConfigSheet(
            config: config,
            locked: true,
            lockedReason: 'agent 运行中，先中断再切换',
            onApply: (p, m, t) async => applied++,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('agent 运行中，先中断再切换'), findsOneWidget);
      await tester.tap(find.text('P1'));
      await tester.pumpAndSettle();
      // Tap was refused: still on the provider level, nothing applied.
      expect(applied, 0);
      expect(find.text('第 1 级 · 选择Provider'), findsOneWidget);
    });

    testWidgets('unlocked sheet selects normally', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ModelConfigSheet(
            config: config,
            autoClose: false,
            onApply: (p, m, t) async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('P1'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 级 · 选择Model'), findsOneWidget);
    });
  });

  group('ModelConfigSheet followup chips (queue/guide)', () {
    testWidgets('renders chips and calls onFollowupChanged', (tester) async {
      String? changed;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ModelConfigSheet(
            config: const SessionModelConfig(),
            onApply: (p, m, t) async {},
            onModeChanged: (mode) async {},
            onFollowupChanged: (mode) async => changed = mode,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('跟随模式'), findsOneWidget);
      expect(find.text('排队'), findsOneWidget);
      expect(find.text('引导'), findsOneWidget);

      await tester.tap(find.text('引导'));
      await tester.pumpAndSettle();
      expect(changed, 'guide');
    });

    testWidgets('currentFollowup preselects the chip', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ModelConfigSheet(
            config: const SessionModelConfig(),
            onApply: (p, m, t) async {},
            currentFollowup: 'guide',
            onFollowupChanged: (mode) async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('引导'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.selected, isTrue);
      // The collaboration-mode chips (build/edit/plan/yolo) are unaffected.
      final queueChip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('排队'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(queueChip.selected, isFalse);
    });
  });
}
