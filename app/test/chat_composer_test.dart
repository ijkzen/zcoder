import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/app_controller.dart';
import 'package:zcode_remote/src/protocol/services/services.dart';
import 'package:zcode_remote/src/ui/chat_composer.dart';

/// Serves canned slash commands / skills without a bridge (same fixtures as
/// command_suggestion_panel_test.dart).
class _FakeApp extends AppController {
  @override
  Future<WorkspacePrep?> fetchWorkspacePrep({bool refresh = false}) async =>
      const WorkspacePrep(
        configOptions: [],
        slashCommands: [
          SlashCommand(name: 'clear', description: '清空会话', source: 'builtin'),
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

Widget _wrap({
  Future<bool> Function(String text)? onSend,
  VoidCallback? onPickAttachment,
  bool busy = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatComposer(
        app: _FakeApp(),
        hintText: 'hint…',
        onSend: onSend ?? (_) async => true,
        onPickAttachment: onPickAttachment,
        busy: busy,
      ),
    ),
  );
}

TextField _field(WidgetTester tester, {bool expanded = false}) {
  final fields = tester
      .widgetList<TextField>(find.byType(TextField))
      .where((f) => (f.expands) == expanded)
      .toList();
  expect(fields, hasLength(1));
  return fields.single;
}

void main() {
  testWidgets(
    'button row: /, \$ and send; image only with attachment callback',
    (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.byTooltip('斜杠命令'), findsOneWidget);
      expect(find.byTooltip('技能命令'), findsOneWidget);
      expect(find.byTooltip('添加附件'), findsNothing);
      expect(find.byTooltip('发送'), findsOneWidget);

      await tester.pumpWidget(_wrap(onPickAttachment: () {}));
      expect(find.byTooltip('添加附件'), findsOneWidget);
    },
  );

  testWidgets('tapping / inserts a slash token and lists slash commands', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.tap(find.byTooltip('斜杠命令'));
    await tester.pumpAndSettle();

    expect(_field(tester).controller!.text, '/');
    expect(find.text('/clear'), findsOneWidget);
  });

  testWidgets(r'tapping $ appends a spaced dollar token after existing text', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byTooltip('技能命令'));
    await tester.pumpAndSettle();

    expect(_field(tester).controller!.text, r'hello $');
    expect(find.text(r'$review'), findsOneWidget);
  });

  testWidgets('image button forwards to the attachment callback', (
    tester,
  ) async {
    var picked = 0;
    await tester.pumpWidget(_wrap(onPickAttachment: () => picked++));
    await tester.tap(find.byTooltip('添加附件'));
    expect(picked, 1);
  });

  testWidgets('send clears the text only when onSend accepts it', (
    tester,
  ) async {
    String? sent;
    var accept = true;
    await tester.pumpWidget(
      _wrap(
        onSend: (text) async {
          sent = text;
          return accept;
        },
      ),
    );

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(sent, 'hi');
    expect(_field(tester).controller!.text, '');

    accept = false;
    await tester.enterText(find.byType(TextField), 'retry me');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(_field(tester).controller!.text, 'retry me');
  });

  testWidgets('compact box: Enter (send action) submits', (tester) async {
    String? sent;
    await tester.pumpWidget(
      _wrap(
        onSend: (text) async {
          sent = text;
          return true;
        },
      ),
    );
    await tester.enterText(find.byType(TextField), 'via enter');
    await tester.showKeyboard(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(sent, 'via enter');
  });

  testWidgets('busy disables send and attachment buttons', (tester) async {
    await tester.pumpWidget(_wrap(onPickAttachment: () {}, busy: true));
    IconButton buttonOf(String tooltip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    expect(buttonOf('发送').onPressed, isNull);
    expect(buttonOf('添加附件').onPressed, isNull);
  });

  testWidgets('expand opens a newline-mode editor sharing the same text', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.tap(find.byTooltip('放大编辑'));
    await tester.pumpAndSettle();

    // The compact box is offstage under the fullscreen dialog route.
    final editor = _field(tester, expanded: true);
    expect(editor.controller!.text, 'draft');
    expect(editor.textInputAction, TextInputAction.newline);
    expect(editor.keyboardType, TextInputType.multiline);

    await tester.enterText(find.byType(EditableText), 'draft\nsecond line');
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(_field(tester).controller!.text, 'draft\nsecond line');
  });

  testWidgets('expanded editor sends via its button row', (tester) async {
    String? sent;
    await tester.pumpWidget(
      _wrap(
        onSend: (text) async {
          sent = text;
          return true;
        },
      ),
    );
    await tester.enterText(find.byType(TextField), 'from expanded');
    await tester.tap(find.byTooltip('放大编辑'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(sent, 'from expanded');
    // Accepted send closes the editor, landing back on the compact composer.
    expect(find.byTooltip('收起'), findsNothing);
    expect(_field(tester).controller!.text, '');
  });

  testWidgets(
    'expanded editor removes itself from under a route pushed during send',
    (tester) async {
      late BuildContext hostContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              hostContext = context;
              return Scaffold(
                body: ChatComposer(
                  app: _FakeApp(),
                  hintText: 'hint…',
                  // Like the sessions page: a successful send pushes the new
                  // conversation ON TOP of the still-open expanded editor.
                  onSend: (_) async {
                    Navigator.of(hostContext).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            const Scaffold(body: Text('new conversation')),
                      ),
                    );
                    return true;
                  },
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.byTooltip('放大编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();

      expect(find.text('new conversation'), findsOneWidget);
      // Backing out of the pushed page must land on the compact composer, not
      // on the stale editor. (No AppBar back button here — pop directly.)
      Navigator.of(hostContext).pop();
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起'), findsNothing);
      expect(find.byTooltip('放大编辑'), findsOneWidget);
    },
  );

  testWidgets('expanded editor mirrors the header live (attachment feedback)', (
    tester,
  ) async {
    final headerSource = ValueNotifier<Widget?>(null);
    addTearDown(headerSource.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<Widget?>(
            valueListenable: headerSource,
            builder: (context, header, _) => ChatComposer(
              app: _FakeApp(),
              hintText: 'hint…',
              onSend: (_) async => true,
              header: header,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('放大编辑'));
    await tester.pumpAndSettle();
    expect(find.text('photo.png'), findsNothing);

    // Host stages an attachment while the editor is open — the chip must
    // appear there too (the editor is a separate route and cannot see the
    // host's rebuilds directly).
    headerSource.value = const InputChip(label: Text('photo.png'));
    await tester.pumpAndSettle();
    expect(find.text('photo.png'), findsOneWidget);

    headerSource.value = null;
    await tester.pumpAndSettle();
    expect(find.text('photo.png'), findsNothing);
  });
}
