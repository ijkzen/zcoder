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

  group('usage (snapshot usage.contextWindow cache hit rate)', () {
    test('applySnapshot parses usage into the state', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
        'usage': {
          'contextWindow': {
            'usedTokens': 90000,
            'maxTokens': 1000000,
            'cache': {'hitRate': 0.981},
          },
          'cumulative': {'inputTokens': 100, 'outputTokens': 20},
        },
      }));
      expect(s.usage?.usedTokens, 90000);
      expect(s.usage?.cacheHitRate, closeTo(0.981, 0.0001));
    });

    test('state.updated patch with usage replaces the field', () {
      final s = state();
      s.applyDelta({
        'op': 'state.updated',
        'patch': {
          'usage': {
            'contextWindow': {
              'usedTokens': 120000,
              'maxTokens': 1000000,
              'cache': {'hitRate': 0.982},
            },
            'cumulative': const {},
          },
        },
      });
      expect(s.usage?.cacheHitRate, closeTo(0.982, 0.0001));
      expect(s.control.containsKey('usage'), isFalse);
    });

    test('usage stays null when no frame carried it', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
      }));
      expect(s.usage, isNull);
      s.applyDelta({'op': 'state.updated', 'patch': {'plan': {'items': []}}});
      expect(s.usage, isNull);
    });
  });

  group('goal menu availability (pause/resume from snapshot availability)', () {
    test('defaults to neither allowed before any snapshot', () {
      final s = state();
      expect(s.canPauseGoal, isFalse);
      expect(s.canResumeGoal, isFalse);
    });

    test('availability via applySnapshot: running goal → pause only', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
        'availability': {
          'fork': {'allowed': true},
          'pauseGoal': {'allowed': true},
          'resumeGoal': {'allowed': false, 'reasonCode': 'no_paused_goal'},
        },
      }));
      expect(s.canPauseGoal, isTrue);
      expect(s.canResumeGoal, isFalse);
    });

    test('availability via state.updated patch: paused goal → resume only', () {
      final s = state();
      s.applyDelta({
        'op': 'state.updated',
        'patch': {
          'availability': {
            'pauseGoal': {'allowed': false, 'reasonCode': 'no_active_goal'},
            'resumeGoal': {'allowed': true},
          },
        },
      });
      expect(s.canPauseGoal, isFalse);
      expect(s.canResumeGoal, isTrue);
    });

    test('no goal → both allowed=false → neither shown', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
        'availability': {
          'pauseGoal': {'allowed': false, 'reasonCode': 'no_goal'},
          'resumeGoal': {'allowed': false, 'reasonCode': 'no_goal'},
        },
      }));
      expect(s.canPauseGoal, isFalse);
      expect(s.canResumeGoal, isFalse);
    });

    test('missing entry (availability arrived without the command) → false', () {
      final s = state();
      s.availability = {
        'compact': {'allowed': true},
      };
      expect(s.canPauseGoal, isFalse);
      expect(s.canResumeGoal, isFalse);
    });
  });

  group('subagents (snapshot registry → runningSubagents)', () {
    test('applySnapshot parses running[] into runningSubagents', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
        'subagents': {
          'revision': 3,
          'childSessionIds': ['child_a', 'child_b'],
          'running': [
            {
              'childSessionId': 'child_a',
              'subagentType': 'Explore',
              'title': '调研资料',
              'summary': '正在阅读文档',
              'status': 'running',
              'startedAt': 1000,
            },
          ],
          'endedTotal': 2,
        },
      }));
      final running = s.runningSubagents;
      expect(running, hasLength(1));
      expect(running.first['childSessionId'], 'child_a');
      expect(running.first['title'], '调研资料');
      expect(running.first['summary'], '正在阅读文档');
    });

    test('state.updated patch replaces the registry (live refresh)', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
        'subagents': {
          'revision': 1,
          'running': [
            {'childSessionId': 'a', 'subagentType': 'Explore', 'status': 'running'},
          ],
          'endedTotal': 0,
        },
      }));
      s.applyDelta({
        'op': 'state.updated',
        'patch': {
          'subagents': {
            'revision': 2,
            'running': [
              {'childSessionId': 'b', 'subagentType': 'Implementer', 'status': 'running'},
            ],
            'endedTotal': 1,
          },
        },
      });
      expect(s.runningSubagents, hasLength(1));
      expect(s.runningSubagents.first['childSessionId'], 'b');
    });

    test('runningSubagents is empty when no registry arrived', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson({
        'sessionId': 'sess_1',
        'logEpoch': 'epoch',
        'seq': 1,
        'revision': 2,
        'rows': {'window': <Object?>[]},
      }));
      expect(s.runningSubagents, isEmpty);
    });

    test('applyReadSession carries subagents when the host inlines it', () {
      final s = state();
      s.applyReadSession({
        'session': {'status': 'running'},
        'subagents': {
          'revision': 1,
          'running': [
            {'childSessionId': 'c', 'subagentType': 'Explore', 'status': 'running'},
          ],
          'endedTotal': 0,
        },
      });
      expect(s.runningSubagents, hasLength(1));
      expect(s.runningSubagents.first['childSessionId'], 'c');
    });
  });
}
