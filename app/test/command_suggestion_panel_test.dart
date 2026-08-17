import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/app_controller.dart';
import 'package:zcode_remote/src/protocol/services/services.dart';
import 'package:zcode_remote/src/ui/command_suggestion_panel.dart';

/// Serves canned slash commands / skills without a bridge.
class _FakeApp extends AppController {
  @override
  Future<WorkspacePrep?> fetchWorkspacePrep({bool refresh = false}) async =>
      const WorkspacePrep(
        configOptions: [],
        slashCommands: [
          SlashCommand(name: 'clear', description: '清空会话', source: 'builtin'),
          SlashCommand(name: 'compact', description: '', source: 'builtin'),
        ],
      );

  @override
  Future<List<SkillEntry>> fetchSkills({bool refresh = false}) async => const [
    SkillEntry(
      id: 's1',
      name: 'review',
      path: '/skills/review',
      scope: 'user',
      description: '审查代码',
      enabled: true,
    ),
  ];
}

class _Harness extends StatefulWidget {
  final AppController app;
  const _Harness({required this.app});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = TextEditingController();
  final focusNode = FocusNode();

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CommandSuggestionPanel(
              app: widget.app,
              controller: controller,
              focusNode: focusNode,
            ),
            TextField(controller: controller, focusNode: focusNode),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('typing a / token lists matching slash commands', (tester) async {
    await tester.pumpWidget(_Harness(app: _FakeApp()));
    await tester.enterText(find.byType(TextField), '/cl');
    await tester.pumpAndSettle();

    expect(find.text('/clear'), findsOneWidget);
    expect(find.text('清空会话'), findsOneWidget);
    expect(find.text('/compact'), findsNothing);
  });

  testWidgets('tapping a suggestion replaces the token and hides the panel', (
    tester,
  ) async {
    await tester.pumpWidget(_Harness(app: _FakeApp()));
    final field = find.byType(TextField);
    await tester.enterText(field, '请 /cl');
    await tester.pumpAndSettle();

    await tester.tap(find.text('/clear'));
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(field);
    expect(textField.controller!.text, '请 /clear ');
    expect(find.text('/clear'), findsNothing);
    expect(find.text('/compact'), findsNothing);
  });

  testWidgets(r'typing a $ token lists matching skills', (tester) async {
    await tester.pumpWidget(_Harness(app: _FakeApp()));
    await tester.enterText(find.byType(TextField), r'$re');
    await tester.pumpAndSettle();

    expect(find.text(r'$review'), findsOneWidget);
    expect(find.text('审查代码'), findsOneWidget);
  });

  testWidgets('plain text shows no suggestions', (tester) async {
    await tester.pumpWidget(_Harness(app: _FakeApp()));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pumpAndSettle();

    expect(find.text('/clear'), findsNothing);
    expect(find.text(r'$review'), findsNothing);
  });
}
