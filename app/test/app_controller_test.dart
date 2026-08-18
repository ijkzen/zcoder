import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/app_controller.dart';

void main() {
  group('suppressCompletionFor (completion-notification suppression)', () {
    bool check({required bool foreground, String? openSessionId, required String sessionId}) =>
        AppController.suppressCompletionFor(
          foreground: foreground,
          openSessionId: openSessionId,
          sessionId: sessionId,
        );

    test('suppresses only when foreground AND the session is the open one', () {
      expect(check(foreground: true, openSessionId: 'a', sessionId: 'a'), isTrue);
      expect(check(foreground: false, openSessionId: 'a', sessionId: 'a'), isFalse);
      expect(check(foreground: true, openSessionId: 'b', sessionId: 'a'), isFalse);
      // No detail page open (same session listed elsewhere) → notify.
      expect(check(foreground: true, openSessionId: null, sessionId: 'a'), isFalse);
    });
  });
}
