import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/services/launcher_badge_ledger.dart';

void main() {
  group('LauncherBadgeLedger', () {
    test('counts distinct sessions once each until cleared', () {
      final ledger = LauncherBadgeLedger();

      // First terminal crossing: counted.
      expect(ledger.add('d|t1'), isTrue);
      expect(ledger.count, 1);

      // Same session crosses again while still unviewed: still one point.
      expect(ledger.add('d|t1'), isFalse);
      expect(ledger.count, 1);

      // A second session adds a second point.
      expect(ledger.add('d|t2'), isTrue);
      expect(ledger.count, 2);
    });

    test('removing a session drops its point and can be counted again', () {
      final ledger = LauncherBadgeLedger()..reset(['d|t1', 'd|t2']);

      expect(ledger.remove('d|t2'), isTrue);
      expect(ledger.count, 1);

      // Removing again is a no-op.
      expect(ledger.remove('d|t2'), isFalse);
      expect(ledger.count, 1);

      // After being viewed (removed), a later crossing counts it anew.
      expect(ledger.add('d|t2'), isTrue);
      expect(ledger.count, 2);
    });

    test('reset replaces the whole ledger', () {
      final ledger = LauncherBadgeLedger()..reset(['d|t1', 'd|t2']);
      ledger.reset(['d|t3']);
      expect(ledger.count, 1);
      expect(ledger.contains('d|t3'), isTrue);
      expect(ledger.contains('d|t1'), isFalse);
    });

    test('session keys are disambiguated per pairing', () {
      final ledger = LauncherBadgeLedger();
      ledger.add('desktopA|t1');
      ledger.add('desktopB|t1');
      expect(ledger.count, 2);
      expect(ledger.remove('desktopA|t1'), isTrue);
      expect(ledger.contains('desktopB|t1'), isTrue);
      expect(ledger.count, 1);
    });
  });
}
