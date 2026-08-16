import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/ui/workspaces_page.dart';

Workspace _task(
  String workspaceKey,
  String taskId, {
  bool archived = false,
}) =>
    Workspace(
      workspaceKey: workspaceKey,
      workspacePath: '/tmp/$workspaceKey',
      workspaceLabel: workspaceKey,
      workspaceKind: 'local',
      connectionState: 'connected',
      taskId: taskId,
      archived: archived,
    );

void main() {
  group('projectDeleteTaskIds', () {
    test('collects every task of the workspace, archived included', () {
      final ids = projectDeleteTaskIds([
        _task('a', 't1'),
        _task('a', 't2', archived: true),
        _task('b', 't3'),
      ], 'a');
      expect(ids, unorderedEquals(['t1', 't2']));
    });

    test('skips rows without a task id and unknown keys', () {
      final ids = projectDeleteTaskIds([
        Workspace(
          workspaceKey: 'a',
          workspacePath: '/tmp/a',
          workspaceLabel: 'a',
          workspaceKind: 'local',
          connectionState: 'connected',
        ),
        _task('b', 't3'),
      ], 'a');
      expect(ids, isEmpty);
    });
  });

  group('confirmDeleteProject dialog', () {
    Future<void> pumpDialog(
      WidgetTester tester, {
      required int taskCount,
      required int visibleCount,
      int runningCount = 0,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => confirmDeleteProject(
                  context,
                  label: 'demo',
                  taskCount: taskCount,
                  visibleCount: visibleCount,
                  runningCount: runningCount,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ));

    testWidgets('mentions archived tasks only when counts differ', (tester) async {
      await pumpDialog(tester, taskCount: 3, visibleCount: 2);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('「demo」'), findsOneWidget);
      expect(find.textContaining('3 个会话'), findsOneWidget);
      expect(find.textContaining('含已归档'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('no archived hint when all tasks are visible', (tester) async {
      await pumpDialog(tester, taskCount: 2, visibleCount: 2);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 个会话'), findsOneWidget);
      expect(find.textContaining('含已归档'), findsNothing);
    });

    testWidgets('warns about running sessions only when present',
        (tester) async {
      await pumpDialog(tester, taskCount: 3, visibleCount: 3, runningCount: 2);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('其中 2 个会话正在运行'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await pumpDialog(tester, taskCount: 1, visibleCount: 1);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在运行'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('confirm uses the destructive (error) style', (tester) async {
      await pumpDialog(tester, taskCount: 1, visibleCount: 1);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('删除'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.style?.backgroundColor?.resolve({}), isNotNull);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除项目'), findsNothing);
    });
  });
}
