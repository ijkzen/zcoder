import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/session/session_status_monitor.dart';

Workspace task(String id, String status) => Workspace(
      workspaceKey: 'ws',
      workspacePath: '/ws',
      workspaceLabel: 'WS',
      workspaceKind: 'local',
      connectionState: 'connected',
      taskId: id,
      displayStatus: status,
    );

void main() {
  group('normalizeTerminalStatus', () {
    test('maps detail phases and list status to coarse buckets', () {
      expect(normalizeTerminalStatus('completedSuccess'), 'completed');
      expect(normalizeTerminalStatus('completedInterrupted'), 'completed');
      expect(normalizeTerminalStatus('completed'), 'completed');
      expect(normalizeTerminalStatus('error'), 'error');
      expect(normalizeTerminalStatus('running'), isNull);
      expect(normalizeTerminalStatus('idle'), isNull);
      expect(normalizeTerminalStatus('draft'), isNull);
    });
  });

  group('SessionStatusMonitor', () {
    test('notifies on running → completed exactly once', () {
      final shared = <String, String>{};
      final monitor = SessionStatusMonitor(shared);

      // Baseline: running only.
      expect(monitor.detect([task('t1', 'running')]), isEmpty);

      // Crossing into completed.
      expect(monitor.detect([task('t1', 'completed')]), [
        (taskId: 't1', workspaceKey: 'ws', status: 'completed'),
      ]);

      // Stayed completed on later ticks: no repeat.
      expect(monitor.detect([task('t1', 'completed')]), isEmpty);
      expect(shared['t1'], 'completed');
    });

    test('first sight of a finished session does not notify', () {
      final monitor = SessionStatusMonitor(<String, String>{});
      // A session that was already completed before the monitor started must
      // not spam a notification on startup.
      expect(monitor.detect([task('t1', 'completed')]), isEmpty);
      expect(monitor.detect([task('t1', 'completed')]), isEmpty);
    });

    test('notifies on idle → error', () {
      final monitor = SessionStatusMonitor(<String, String>{});
      expect(monitor.detect([task('t1', 'idle')]), isEmpty);
      expect(monitor.detect([task('t1', 'error')]), [
        (taskId: 't1', workspaceKey: 'ws', status: 'error'),
      ]);
    });

    test('monitors every workspace, not just the active one', () {
      final monitor = SessionStatusMonitor(<String, String>{});
      final wsA = Workspace(
        workspaceKey: 'ws-a',
        workspacePath: '/a',
        workspaceLabel: 'A',
        workspaceKind: 'local',
        connectionState: 'connected',
        taskId: 'a1',
        displayStatus: 'running',
      );
      final wsB = Workspace(
        workspaceKey: 'ws-b',
        workspacePath: '/b',
        workspaceLabel: 'B',
        workspaceKind: 'local',
        connectionState: 'connected',
        taskId: 'b1',
        displayStatus: 'running',
      );
      expect(monitor.detect([wsA, wsB]), isEmpty);
      expect(monitor.detect([
        Workspace(
          workspaceKey: 'ws-a',
          workspacePath: '/a',
          workspaceLabel: 'A',
          workspaceKind: 'local',
          connectionState: 'connected',
          taskId: 'a1',
          displayStatus: 'completed',
        ),
        Workspace(
          workspaceKey: 'ws-b',
          workspacePath: '/b',
          workspaceLabel: 'B',
          workspaceKind: 'local',
          connectionState: 'connected',
          taskId: 'b1',
          displayStatus: 'completed',
        ),
      ]), [
        (taskId: 'a1', workspaceKey: 'ws-a', status: 'completed'),
        (taskId: 'b1', workspaceKey: 'ws-b', status: 'completed'),
      ]);
    });

    test('skips a crossing the detail page already notified', () {
      final shared = <String, String>{'t1': 'completed'};
      final monitor = SessionStatusMonitor(shared);

      expect(monitor.detect([task('t1', 'running')]), isEmpty);
      expect(monitor.detect([task('t1', 'completed')]), isEmpty);
    });

    test('two sources sharing the map never double-notify', () {
      final shared = <String, String>{};
      final monitor = SessionStatusMonitor(shared);

      // Detail page wins the race: it recorded completedSuccess first.
      shared['t1'] = normalizeTerminalStatus('completedSuccess')!;
      expect(monitor.detect([task('t1', 'running')]), isEmpty);
      expect(monitor.detect([task('t1', 'completed')]), isEmpty);

      // Reverse: the list monitor fires first, the detail path then sees the
      // bucket already taken.
      shared.clear();
      expect(monitor.detect([task('t1', 'running')]), isEmpty);
      final events = monitor.detect([task('t1', 'completed')]);
      expect(events.single.taskId, 't1');
      expect(normalizeTerminalStatus('completedSuccess'), shared['t1']);
    });
  });
}