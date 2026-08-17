import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/ui/request_sheet.dart';

PendingRequest permission({
  String requestId = 'perm_1',
  String toolName = 'Bash',
  String reason = '允许执行 bash 命令？',
  String riskLevel = 'medium',
  Map<String, Object?> input = const {},
  Map<String, Object?>? origin,
  List<PendingRequestOption> options = const [
    PendingRequestOption(optionId: 'allow_once', kind: 'allow_once', name: '允许一次'),
    PendingRequestOption(optionId: 'allow_always', kind: 'allow_always', name: '始终允许'),
    PendingRequestOption(optionId: 'deny', kind: 'deny', name: '拒绝'),
  ],
}) =>
    PendingRequest(
      requestId: requestId,
      toolCallId: 'call_1',
      toolName: toolName,
      reason: reason,
      riskLevel: riskLevel,
      input: input,
      options: options,
      requestedAt: 1,
      origin: origin,
    );

PendingRequest question({
  String requestId = 'perm_2',
  Map<String, Object?>? origin,
  List<Map<String, Object?>>? questions,
}) =>
    PendingRequest(
      requestId: requestId,
      toolName: 'AskUserQuestion',
      reason: '需要你的回答',
      input: {
        'questions': questions ??
            [
              {
                'question': '选一个颜色',
                'options': [
                  {'value': 'Red', 'label': '红色'},
                  {'value': 'Blue', 'label': '蓝色'},
                ],
                'multiSelect': false,
              },
            ],
      },
      requestedAt: 2,
      origin: origin,
    );

PendingRequest freeText({
  String requestId = 'perm_3',
  Map<String, Object?>? origin,
}) =>
    PendingRequest(
      requestId: requestId,
      toolName: 'AskUserQuestion',
      reason: '请输入内容',
      input: {'freeText': true, 'prompt': '描述一下你的想法'},
      requestedAt: 3,
      origin: origin,
    );

void main() {
  group('PendingRequest classification', () {
    test('permission requests are not elicitations', () {
      final p = permission();
      expect(p.hasQuestions, isFalse);
      expect(p.isFreeTextInput, isFalse);
      expect(p.isExitPlanMode, isFalse);
      expect(p.isElicitation, isFalse);
      expect(p.prompt, '允许执行 bash 命令？');
    });

    test('AskUserQuestion with questions is an elicitation', () {
      final q = question();
      expect(q.hasQuestions, isTrue);
      expect(q.isElicitation, isTrue);
      expect(q.questions.single.question, '选一个颜色');
    });

    test('freeText input is an elicitation but not a permission', () {
      final f = freeText();
      expect(f.isFreeTextInput, isTrue);
      expect(f.isElicitation, isTrue);
      expect(f.questions, isEmpty);
    });

    test('ExitPlanMode is an elicitation', () {
      final e = PendingRequest(
        requestId: 'perm_4',
        toolName: 'ExitPlanMode',
        reason: '计划审批',
        input: {'interaction': 'plan_approval', 'plan': '重构模块 A'},
      );
      expect(e.isExitPlanMode, isTrue);
      expect(e.isElicitation, isTrue);
      expect(e.isFreeTextInput, isFalse);
    });

    test('permission with a prompt-like arg is still a permission', () {
      // A tool whose args happen to contain a "prompt" key must not be
      // misclassified — only freeText: true marks a real free-text input.
      final p = PendingRequest(
        requestId: 'perm_5',
        toolName: 'SomeTool',
        reason: '批准',
        input: {'prompt': 'some tool arg'},
        options: const [PendingRequestOption(optionId: 'allow', kind: 'allow_once')],
      );
      expect(p.isFreeTextInput, isFalse);
      expect(p.isElicitation, isFalse);
    });

    test('option kind labels', () {
      expect(PendingRequest.optionKindLabel('allow_once'), '允许一次');
      expect(PendingRequest.optionKindLabel('allowOnce'), '允许一次');
      expect(PendingRequest.optionKindLabel('allow_always'), '始终允许');
      expect(PendingRequest.optionKindLabel('deny'), '拒绝');
      expect(PendingRequest.optionKindLabel('custom'), '自定义');
      expect(PendingRequest.optionKindLabel('unknown'), '');
    });
  });

  group('RequestSheet', () {
    Future<List<Map<String, Object?>>> pumpSheet(
      WidgetTester tester,
      List<PendingRequest> requests,
    ) async {
      final answers = <Map<String, Object?>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RequestSheet(
            requests: requests,
            onResolve: (request, answer) async {
              answers.add(answer);
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return answers;
    }

    testWidgets('permission page renders options and resolves with optionId',
        (tester) async {
      final answers = await pumpSheet(tester, [permission()]);

      expect(find.text('需要批准'), findsOneWidget);
      expect(find.text('允许执行 bash 命令？'), findsOneWidget);
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('允许一次'), findsOneWidget);
      expect(find.text('始终允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);

      await tester.tap(find.text('允许一次'));
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();

      expect(answers, [
        {'optionId': 'allow_once'},
      ]);
    });

    testWidgets('permission page shows the Bash command being approved',
        (tester) async {
      await pumpSheet(tester, [
        permission(input: {'command': 'rm -rf /tmp/x'}),
      ]);

      expect(find.text('命令'), findsOneWidget);
      expect(find.text('rm -rf /tmp/x'), findsOneWidget);
      // A Bash command is shown verbatim, not as JSON.
      expect(find.textContaining('"command"'), findsNothing);
    });

    testWidgets('non-Bash permission shows the input as pretty JSON',
        (tester) async {
      await pumpSheet(tester, [
        permission(
          toolName: 'Read',
          reason: '读取文件？',
          input: {'file_path': '/etc/hosts'},
        ),
      ]);

      expect(find.text('文件'), findsOneWidget);
      expect(find.text('/etc/hosts'), findsOneWidget);
      expect(find.textContaining('"file_path"'), findsNothing);
    });

    testWidgets('Edit permission shows the file and the line-change stat',
        (tester) async {
      await pumpSheet(tester, [
        permission(
          toolName: 'Edit',
          reason: '编辑文件？',
          input: {
            'file_path': 'lib/foo.dart',
            'old_string': 'line1\nline2\nline3',
            'new_string': 'line1\nline2\nline3\nline4\nline5',
          },
        ),
      ]);

      expect(find.text('文件'), findsOneWidget);
      expect(find.text('lib/foo.dart'), findsOneWidget);
      expect(find.text('改动'), findsOneWidget);
      expect(find.text('−3 行 +5 行'), findsOneWidget);
    });

    testWidgets('Write permission shows the file and the content size',
        (tester) async {
      await pumpSheet(tester, [
        permission(
          toolName: 'Write',
          reason: '写入文件？',
          input: {'file_path': 'a.txt', 'content': 'x\ny\nz'},
        ),
      ]);

      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
      expect(find.text('3 行'), findsOneWidget);
    });

    testWidgets('search permission shows the term', (tester) async {
      await pumpSheet(tester, [
        permission(
          toolName: 'Grep',
          reason: '搜索？',
          input: {'pattern': 'FIXME', 'path': 'lib'},
        ),
      ]);

      expect(find.text('搜索'), findsOneWidget);
      expect(find.text('FIXME'), findsOneWidget);
    });

    testWidgets('unknown tool falls back to the raw input as JSON',
        (tester) async {
      await pumpSheet(tester, [
        permission(
          toolName: 'SomeCustomTool',
          reason: '执行自定义工具？',
          input: {'arg': 'value'},
        ),
      ]);

      expect(find.text('参数'), findsOneWidget);
      expect(find.textContaining('"arg"'), findsOneWidget);
      expect(find.textContaining('value'), findsOneWidget);
    });

    testWidgets('mcp tool falls back to the raw input as JSON',
        (tester) async {
      await pumpSheet(tester, [
        permission(
          toolName: 'mcp__kimi-cu__click',
          reason: 'MCP 工具？',
          input: {'x': 10, 'y': 20},
        ),
      ]);

      expect(find.text('参数'), findsOneWidget);
      expect(find.textContaining('"x"'), findsOneWidget);
      expect(find.textContaining('"y"'), findsOneWidget);
    });

    testWidgets('permission without input shows no detail block',
        (tester) async {
      await pumpSheet(tester, [permission(input: const {})]);

      expect(find.text('命令'), findsNothing);
      expect(find.text('参数'), findsNothing);
      expect(find.text('文件'), findsNothing);
      expect(find.text('改动'), findsNothing);
    });

    testWidgets('subagent permission shows the 来自子智能体 badge',
        (tester) async {
      await pumpSheet(tester, [
        permission(
          origin: {
            'kind': 'subagent',
            'agentId': 'agent_explore',
            'agentType': 'explore',
            'childSessionId': 'sess_child',
            'parentSessionId': 'sess_parent',
          },
        ),
      ]);

      expect(find.text('来自子智能体'), findsOneWidget);
      expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    });

    testWidgets('main-agent permission has no subagent badge', (tester) async {
      await pumpSheet(tester, [permission()]);

      expect(find.text('来自子智能体'), findsNothing);
      expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    });

    testWidgets('subagent question shows the 来自子智能体 badge',
        (tester) async {
      await pumpSheet(tester, [
        question(
          origin: {
            'kind': 'subagent',
            'agentId': 'agent_explore',
            'agentType': 'explore',
            'childSessionId': 'sess_child',
            'parentSessionId': 'sess_parent',
          },
        ),
      ]);

      expect(find.text('来自子智能体'), findsOneWidget);
      expect(find.text('可多选'), findsNothing);
      expect(find.text('单选'), findsOneWidget);
    });

    testWidgets('main-agent question has no subagent badge', (tester) async {
      await pumpSheet(tester, [question()]);
      expect(find.text('来自子智能体'), findsNothing);
    });

    testWidgets('subagent freeText shows the 来自子智能体 badge',
        (tester) async {
      await pumpSheet(tester, [
        freeText(
          origin: {
            'kind': 'subagent',
            'agentId': 'agent_explore',
            'childSessionId': 'sess_child',
            'parentSessionId': 'sess_parent',
          },
        ),
      ]);

      expect(find.text('来自子智能体'), findsOneWidget);
      expect(find.text('描述一下你的想法'), findsOneWidget);
    });

    testWidgets('main-agent freeText has no subagent badge', (tester) async {
      await pumpSheet(tester, [freeText()]);
      expect(find.text('来自子智能体'), findsNothing);
    });

    testWidgets('cancel on a permission picks the deny option', (tester) async {
      final answers = await pumpSheet(tester, [permission()]);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answers, [
        {'optionId': 'deny'},
      ]);
    });

    testWidgets('cancel on a permission without deny just closes',
        (tester) async {
      final answers = await pumpSheet(tester, [
        permission(
          options: const [
            PendingRequestOption(optionId: 'allow_once', kind: 'allow_once', name: '允许一次'),
          ],
        ),
      ]);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answers, isEmpty);
    });

    testWidgets('question page resolves with action accept and content',
        (tester) async {
      final answers = await pumpSheet(tester, [question()]);

      expect(find.text('需要你的回答'), findsOneWidget);
      expect(find.text('选一个颜色'), findsOneWidget);

      await tester.tap(find.text('红色'));
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();

      expect(answers, hasLength(1));
      final answer = answers.single;
      expect(answer['action'], 'accept');
      final content = answer['content'] as Map<String, Object?>;
      expect(content['answers'], {'选一个颜色': 'Red'});
      expect(content['answer_0'], 'Red');
      expect(content['answer'], 'Red');
    });

    testWidgets('cancel on a question sends action decline (desktop parity)',
        (tester) async {
      final answers = await pumpSheet(tester, [question()]);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answers, [
        {'action': 'decline'},
      ]);
    });

    testWidgets('freeText page resolves with freeText', (tester) async {
      final answers = await pumpSheet(tester, [freeText()]);

      expect(find.text('描述一下你的想法'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '我的回答');
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();

      expect(answers, [
        {'freeText': '我的回答'},
      ]);
    });

    testWidgets('freeText page has no cancel button (desktop parity)',
        (tester) async {
      await pumpSheet(tester, [freeText()]);
      expect(find.text('取消'), findsNothing);
      expect(find.text('提交'), findsOneWidget);
    });

    testWidgets('submit with unanswered pages jumps to the first gap',
        (tester) async {
      final answers = <Map<String, Object?>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RequestSheet(
            requests: [
              question(requestId: 'perm_q1'),
              question(
                requestId: 'perm_q2',
                questions: [
                  {
                    'question': '选一个框架',
                    'options': [
                      {'value': 'F1', 'label': '框架一'},
                    ],
                    'multiSelect': false,
                  },
                ],
              ),
            ],
            onResolve: (request, answer) async => answers.add(answer),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Answer only the first question, then go to the last page and submit.
      await tester.tap(find.text('红色'));
      await tester.pumpAndSettle();
      // Now on page 2 (unanswered). 提交 must not resolve anything and must
      // bounce back to the unanswered page — which is the current one, so the
      // answer set stays empty.
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(answers, isEmpty);
      expect(find.text('选一个框架'), findsOneWidget);
    });

    testWidgets('failed submit keeps the sheet and the answers',
        (tester) async {
      var attempts = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RequestSheet(
            requests: [permission()],
            onResolve: (request, answer) async {
              attempts++;
              if (attempts == 1) throw StateError('network down');
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('允许一次'));
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();

      // Sheet still open, error shown inline, selection preserved.
      expect(find.textContaining('提交失败'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // Retry succeeds and closes the loop.
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.textContaining('提交失败'), findsNothing);
    });

    testWidgets('live listenable: resolved pages vanish, empty auto-closes',
        (tester) async {
      final notifier = ValueNotifier<List<PendingRequest>>([
        permission(requestId: 'perm_a'),
        permission(requestId: 'perm_b', toolName: 'Read', reason: '读取文件？'),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RequestSheet(
            requests: notifier.value,
            requestsListenable: notifier,
            onResolve: (request, answer) async {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('允许执行 bash 命令？'), findsOneWidget);

      // The first request gets resolved elsewhere → its page disappears.
      notifier.value = [
        permission(requestId: 'perm_b', toolName: 'Read', reason: '读取文件？'),
      ];
      await tester.pumpAndSettle();
      expect(find.text('允许执行 bash 命令？'), findsNothing);
      expect(find.text('读取文件？'), findsOneWidget);

      // A new request arriving appends a page.
      notifier.value = [
        permission(requestId: 'perm_b', toolName: 'Read', reason: '读取文件？'),
        permission(requestId: 'perm_c', toolName: 'Edit', reason: '写入文件？'),
      ];
      await tester.pumpAndSettle();
      expect(find.text('读取文件？'), findsOneWidget);
      // (perm_c's page exists in the PageView even if not currently visible.)
    });

    testWidgets('mixed permission + question list pages and resolves each',
        (tester) async {
      final answers = await pumpSheet(
          tester, [permission(requestId: 'perm_a'), question(requestId: 'perm_b')]);

      // First page: the permission.
      expect(find.text('需要批准'), findsNothing); // mixed title
      expect(find.text('需要处理'), findsOneWidget);
      expect(find.text('允许执行 bash 命令？'), findsOneWidget);

      // Answer it and advance to the question page.
      await tester.tap(find.text('始终允许'));
      await tester.pump();
      await tester.tap(find.text('下一题'));
      await tester.pumpAndSettle();
      expect(find.text('选一个颜色'), findsOneWidget);

      await tester.tap(find.text('蓝色'));
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();

      expect(answers, hasLength(2));
      expect(answers[0], {'optionId': 'allow_always'});
      expect(answers[1]['action'], 'accept');
    });
  });
}
