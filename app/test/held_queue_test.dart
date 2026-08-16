import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/protocol/topics/topic_session.dart';
import 'package:zcode_remote/src/session/conversation_controller.dart';

void main() {
  ConversationState state() =>
      ConversationState(sessionId: 'sess_1', logEpoch: 'epoch');

  Map<String, Object?> snapshotJson({Map<String, Object?>? queue}) => {
    'sessionId': 'sess_1',
    'logEpoch': 'epoch',
    'seq': 1,
    'revision': 2,
    'rows': {'window': <Object?>[]},
    'queue': ?queue,
  };

  group('ConversationSnapshot queue parsing', () {
    test('parses queue with items, passthrough of extra keys', () {
      final snapshot = ConversationSnapshot.fromJson(snapshotJson(queue: {
        'items': [
          {
            'queueItemId': 'q1',
            'text': 'hello',
            'createdAt': 123,
            'attachments': <Object?>[],
          },
          {'queueItemId': 'q2', 'text': 'world'},
        ],
        'autoDrain': false,
      }));
      final q = snapshot.queue!;
      expect(q['autoDrain'], false);
      final items = q['items'] as List;
      expect(items, hasLength(2));
      final first = items.first as Map<String, Object?>;
      expect(first['queueItemId'], 'q1');
      expect(first['text'], 'hello');
      expect(first['createdAt'], 123); // verbatim passthrough
    });

    test('queue absent → null (default state)', () {
      final snapshot = ConversationSnapshot.fromJson(snapshotJson());
      expect(snapshot.queue, isNull);
    });

    test('applySnapshot carries queue into the state', () {
      final s = state();
      s.applySnapshot(ConversationSnapshot.fromJson(snapshotJson(queue: {
        'items': [
          {'queueItemId': 'q1', 'text': 'hi'},
        ],
      })));
      expect(s.queueItems, hasLength(1));
      expect(s.queueItems.first['text'], 'hi');
    });
  });

  group('ConversationState queue getters', () {
    test('defaults: empty items, autoDrain true, mode startNow', () {
      final s = state();
      expect(s.queueItems, isEmpty);
      expect(s.autoDrain, isTrue);
      expect(s.inputRoutingMode, 'startNow');
    });

    test('reads queue items, autoDrain false, and inputRouting.mode', () {
      final s = state();
      s.queue = {
        'items': [
          {'queueItemId': 'q1', 'text': 'a'},
          {'queueItemId': 'q2', 'text': 'b'},
        ],
        'autoDrain': false,
      };
      s.inputRouting = {'mode': 'enqueue'};
      expect(s.queueItems, hasLength(2));
      expect(s.queueItems[1]['queueItemId'], 'q2');
      expect(s.autoDrain, isFalse);
      expect(s.inputRoutingMode, 'enqueue');
    });

    test('non-list items degrade to an empty list', () {
      final s = state();
      s.queue = {'items': 'not-a-list', 'autoDrain': true};
      expect(s.queueItems, isEmpty);
      expect(s.autoDrain, isTrue);
    });
  });

  group('applyDelta state.updated dispatch (doc 08 §4.3)', () {
    test('patch.queue lands on state.queue, never inside control', () {
      final s = state();
      s.control = {'phase': 'running', 'canStop': true};
      s.applyDelta({
        'op': 'state.updated',
        'patch': {
          'queue': {
            'items': [
              {'queueItemId': 'q1', 'text': 'hi'},
            ],
            'autoDrain': false,
          },
        },
      });
      expect(s.queue?['autoDrain'], false);
      expect(s.control.containsKey('queue'), isFalse);
      // Existing control keys survive untouched.
      expect(s.control['phase'], 'running');
      expect(s.control['canStop'], true);
    });

    test('patch.control deep-merges, preserving keys not in the patch', () {
      final s = state();
      s.control = {'phase': 'running', 'canStop': true};
      s.applyDelta({
        'op': 'state.updated',
        'patch': {'control': {'canStop': false}},
      });
      expect(s.control['phase'], 'running');
      expect(s.control['canStop'], false);
    });

    test('inputRouting / meta / config / availability replace their fields', () {
      final s = state();
      s.applyDelta({
        'op': 'state.updated',
        'patch': {
          'inputRouting': {'mode': 'guide'},
          'meta': {'title': 't'},
          'config': {'followupMode': 'queue'},
          'availability': {'queueEdit': {'allowed': true}},
        },
      });
      expect(s.inputRouting?['mode'], 'guide');
      expect(s.meta?['title'], 't');
      expect(s.config?['followupMode'], 'queue');
      expect(s.availability?['queueEdit'], isNotNull);
    });

    test('unknown patch keys are ignored without throwing', () {
      final s = state();
      s.applyDelta({
        'op': 'state.updated',
        'patch': {'somethingElse': 42},
      });
      expect(s.queue, isNull);
      expect(s.control, isEmpty);
    });
  });

  group('optimistic queue updates (doc 08 §4.5)', () {
    ConversationState queued() {
      final s = state();
      s.queue = {
        'items': [
          {'queueItemId': 'q1', 'text': 'first'},
          {'queueItemId': 'q2', 'text': 'second'},
        ],
        'autoDrain': true,
      };
      return s;
    }

    test('removeQueueItem removes only the matching id', () {
      final s = queued();
      s.removeQueueItem('q1');
      expect(s.queueItems.map((i) => i['queueItemId']), ['q2']);
      expect(s.autoDrain, isTrue); // unrelated keys survive
    });

    test('removeQueueItem is safe on a null queue and on no match', () {
      state().removeQueueItem('q1'); // null queue → no-op
      final s = queued();
      s.removeQueueItem('nope');
      expect(s.queueItems, hasLength(2));
    });

    test('updateQueueItemText edits the matching item only', () {
      final s = queued();
      s.updateQueueItemText('q2', 'edited');
      expect(s.queueItems[1]['text'], 'edited');
      expect(s.queueItems[0]['text'], 'first');
    });

    test('updateQueueItemText is safe on a null queue', () {
      state().updateQueueItemText('q1', 'x'); // no-op
    });

    test('setAutoDrainOptimistic toggles the switch', () {
      final s = queued();
      s.setAutoDrainOptimistic(false);
      expect(s.autoDrain, isFalse);
      s.setAutoDrainOptimistic(true);
      expect(s.autoDrain, isTrue);
    });

    test('setFollowupModeOptimistic merges into config', () {
      final s = state();
      s.config = {'mode': 'build'};
      s.setFollowupModeOptimistic('guide');
      expect(s.config?['mode'], 'build');
      expect(s.config?['followupMode'], 'guide');
    });
  });

  group('queue command envelopes (buildCommand)', () {
    Map<String, Object?> envelope(String type, Map<String, Object?> payload) =>
        buildCommand(commandId: 'cmd_1', clientId: 'me', type: type, payload: payload);

    test('queue management commands carry the documented payloads', () {
      final queuedNow = envelope('sendQueuedNow', {'queueItemId': 'q1'});
      expect(queuedNow['type'], 'sendQueuedNow');
      expect((queuedNow['payload'] as Map)['queueItemId'], 'q1');

      final edit = envelope('editQueueItem', {
        'queueItemId': 'q1',
        'newText': 'edited',
      });
      expect((edit['payload'] as Map)['newText'], 'edited');

      final delete = envelope('deleteQueueItem', {'queueItemId': 'q1'});
      expect((delete['payload'] as Map)['queueItemId'], 'q1');

      final reorder = envelope('reorderQueueItem', {
        'queueItemId': 'q1',
        'beforeQueueItemId': 'q2',
      });
      expect((reorder['payload'] as Map)['beforeQueueItemId'], 'q2');

      final drain = envelope('setAutoDrain', {'autoDrain': false});
      expect((drain['payload'] as Map)['autoDrain'], false);
    });

    test('sendText envelope carries heldQueueDisposition and expected ids', () {
      final env = envelope('sendText', {
        'text': 'hi',
        'heldQueueDisposition': 'clearQueueAndSend',
        'expectedHeldQueueItemIds': ['q1', 'q2'],
      });
      final payload = env['payload'] as Map;
      expect(payload['heldQueueDisposition'], 'clearQueueAndSend');
      expect(payload['expectedHeldQueueItemIds'], ['q1', 'q2']);
    });

    test('CAS: baseRevision/baseLogEpoch attach when the snapshot is valid', () {
      final env = buildCommand(
        commandId: 'cmd_1',
        clientId: 'me',
        type: 'setAutoDrain',
        payload: {'autoDrain': true},
        baseRevision: 7,
        baseLogEpoch: 'epoch',
      );
      expect(env['baseRevision'], 7);
      expect(env['baseLogEpoch'], 'epoch');
    });
  });
}
