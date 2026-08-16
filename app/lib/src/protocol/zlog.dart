/// App-wide protocol log.
///
/// `debugPrint` is a no-op in release builds, which makes field debugging of
/// the wire protocol impossible on release packages. This helper routes
/// through `print()` (which reaches logcat in every build mode) only when the
/// app is built with `--dart-define=ZREMOTE_LOG=true`; otherwise it compiles
/// to a no-op with zero overhead.
library;

const bool zremoteLogEnabled = bool.fromEnvironment('ZREMOTE_LOG');

void zlog(String message) {
  if (zremoteLogEnabled) {
    // ignore: avoid_print
    print('[zremote] $message');
  }
}
