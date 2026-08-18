import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/app_controller.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/ui/model_config_sheet.dart';
import 'package:zcode_remote/src/ui/sessions_page.dart';

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

  group('ModelConfigSheet 完成 applies pending model selection', () {
    final config = SessionModelConfig(
      provider: 'p1',
      model: 'm1',
      thoughtLevel: 'high',
      availableModels: const [
        ModelOption(
          provider: 'p1',
          providerLabel: 'P1',
          model: 'm1',
          label: 'Model One',
          reasoningLevels: [
            ThoughtLevelOption(value: 'low', label: 'low'),
            ThoughtLevelOption(value: 'high', label: 'high'),
          ],
        ),
        ModelOption(
          provider: 'p1',
          providerLabel: 'P1',
          model: 'm2',
          label: 'Model Two',
          reasoningLevels: [
            ThoughtLevelOption(value: 'low', label: 'low'),
            ThoughtLevelOption(value: 'high', label: 'high'),
          ],
        ),
      ],
    );

    Future<void> openSheet(
      WidgetTester tester,
      Future<void> Function(String p, String m, String? t) onApply,
    ) async {
      // Phone-sized surface so the sheet (list height = 42% of screen) fits.
      tester.view.physicalSize = const Size(1080, 2160);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => ModelConfigSheet(
                    config: config,
                    autoClose: false,
                    onApply: onApply,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('model tap + 完成 (no thought tap) applies with current thought',
        (tester) async {
      final applied = <List<String?>>[];
      await openSheet(tester, (p, m, t) async => applied.add([p, m, t]));

      await tester.tap(find.text('P1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model Two'));
      await tester.pumpAndSettle();
      // Thought level reached, nothing applied yet.
      expect(applied, isEmpty);
      expect(find.text('第 3 级 · 选择Thought'), findsOneWidget);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(
        applied,
        [
          ['p1', 'm2', 'high'],
        ],
      );
      // Sheet closed.
      expect(find.text('完成'), findsNothing);
    });

    testWidgets('thought tap applies immediately; 完成 does not double-apply',
        (tester) async {
      final applied = <List<String?>>[];
      await openSheet(tester, (p, m, t) async => applied.add([p, m, t]));

      await tester.tap(find.text('P1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model Two'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('low'));
      await tester.pumpAndSettle();
      expect(
        applied,
        [
          ['p1', 'm2', 'low'],
        ],
      );

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(applied.length, 1);
    });

    testWidgets('完成 with provider only applies nothing', (tester) async {
      final applied = <List<String?>>[];
      await openSheet(tester, (p, m, t) async => applied.add([p, m, t]));

      await tester.tap(find.text('P1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(applied, isEmpty);
    });
  });

  group('effectiveSessionModelConfig (create-session model = workspace sync)', () {
    final ws = SessionModelConfig(
      provider: 'ws-prov',
      model: 'ws-model',
      thoughtLevel: 'max',
      mode: 'build',
    );

    test('no picker selection → uses the workspace-synced current', () {
      final c = effectiveSessionModelConfig(workspace: ws);
      expect(c.provider, 'ws-prov');
      expect(c.model, 'ws-model');
      expect(c.thoughtLevel, 'max');
      expect(c.mode, 'build');
    });

    test('partial picker selection overrides only the picked fields', () {
      final c = effectiveSessionModelConfig(
        workspace: ws,
        draftProvider: 'draft-prov',
        draftModel: 'draft-model',
      );
      expect(c.provider, 'draft-prov');
      expect(c.model, 'draft-model');
      // Unpicked fields keep the workspace-synced values.
      expect(c.thoughtLevel, 'max');
      expect(c.mode, 'build');
    });

    test('full picker selection wins entirely', () {
      final c = effectiveSessionModelConfig(
        workspace: ws,
        draftProvider: 'd1',
        draftModel: 'm1',
        draftThought: 'low',
        draftMode: 'plan',
      );
      expect(c.provider, 'd1');
      expect(c.model, 'm1');
      expect(c.thoughtLevel, 'low');
      expect(c.mode, 'plan');
    });

    test('workspace not synced (offline) → picker selection only', () {
      final c = effectiveSessionModelConfig(
        workspace: null,
        draftProvider: 'd2',
        draftModel: 'm2',
      );
      expect(c.provider, 'd2');
      expect(c.model, 'm2');
      expect(c.thoughtLevel, isNull);
      expect(c.mode, isNull);
    });
  });
}
