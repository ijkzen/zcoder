import 'package:flutter_test/flutter_test.dart';
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
}
