import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/session/conversation_controller.dart';

void main() {
  ConversationState state() =>
      ConversationState(sessionId: 'sess_1', logEpoch: 'epoch');

  group('isAgentRunning (stop-button visibility)', () {
    test('defaults to false before any readSession poll lands', () {
      expect(state().isAgentRunning, isFalse);
    });

    test('true while session.status is running, false when idle/error', () {
      final s = state();
      s.applyReadSession({
        'session': {'status': 'running'},
      });
      expect(s.isAgentRunning, isTrue);

      s.applyReadSession({
        'session': {'status': 'idle'},
      });
      expect(s.isAgentRunning, isFalse);

      s.applyReadSession({
        'session': {'status': 'error'},
      });
      expect(s.isAgentRunning, isFalse);
    });

    test('event-push control.canStop=true also counts as running', () {
      final s = state();
      s.control = {'canStop': true};
      expect(s.isAgentRunning, isTrue);

      s.control = {'canStop': false};
      s.applyReadSession({
        'session': {'status': 'running'},
      });
      expect(s.isAgentRunning, isTrue);
    });

    test('applyReadSession without a session layer keeps the last status', () {
      final s = state();
      s.applyReadSession({
        'session': {'status': 'running'},
      });
      s.applyReadSession({'settings': {}});
      expect(s.sessionStatus, 'running');
    });
  });

  group('plan / todos (snapshot plan + readSession todos)', () {
    test('applySnapshot carries the plan into the state', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
        'plan': {
          'items': [
            {'id': 't1', 'content': 'first', 'status': 'inProgress'},
            {'id': 't2', 'content': 'done', 'status': 'completed'},
          ],
          'updatedAt': 123,
        },
      }));
      final items = s.plan?['items'] as List;
      expect(items, hasLength(2));
      expect((items[0] as Map)['status'], 'inProgress'); // camelCase passthrough
    });

    test('state.updated patch with plan replaces the field', () {
      final s = state();
      s.applyDelta({
        'op': 'state.updated',
        'patch': {
          'plan': {
            'items': [
              {'id': 't1', 'content': 'only', 'status': 'pending'},
            ],
          },
        },
      });
      expect(s.plan?['items'], hasLength(1));
      // not shoved into control
      expect(s.control.containsKey('plan'), isFalse);
    });

    test('applyReadSession parses todos and flattens todoGroups', () {
      final s = state();
      s.applyReadSession({
        'todos': [
          {'content': 'a', 'status': 'pending', 'priority': 'high'},
        ],
        'todoGroups': [
          {
            'id': 'g1',
            'source': 'session',
            'todos': [
              {'content': 'b', 'status': 'in_progress'},
            ],
          },
        ],
      });
      // todoGroups (grouped) wins over the flat list when non-empty.
      expect(s.readSessionTodos, hasLength(1));
      expect(s.readSessionTodos!.first['content'], 'b');
    });

    test('readSession without todos keeps the field null', () {
      final s = state();
      s.applyReadSession({'session': {'status': 'idle'}});
      expect(s.readSessionTodos, isNull);
    });

    test('plan stays null when the snapshot has none', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
      }));
      expect(s.plan, isNull);
    });
  });
}
