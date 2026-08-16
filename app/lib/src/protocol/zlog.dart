/// App-wide protocol log.
///
/// Every zlog line lands in an in-memory ring buffer, shown by the protocol
/// log page (works in any build). When the app is built with
/// `--dart-define=ZREMOTE_LOG=true` the same line also goes through `print()`
/// (which reaches logcat in every build mode) for field debugging.
library;

import 'dart:async';

const bool zremoteLogEnabled = bool.fromEnvironment('ZREMOTE_LOG');

class LogEntry {
  final DateTime at;
  final String message;
  const LogEntry(this.at, this.message);
}

/// Bounded ring buffer of recent protocol log lines.
class ProtocolLog {
  ProtocolLog._();
  static final ProtocolLog instance = ProtocolLog._();

  static const int capacity = 1000;
  final List<LogEntry> _entries = [];
  final _controller = StreamController<LogEntry>.broadcast();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  Stream<LogEntry> get stream => _controller.stream;

  void add(String message) {
    final entry = LogEntry(DateTime.now(), message);
    if (_entries.length >= capacity) {
      _entries.removeAt(0);
    }
    _entries.add(entry);
    if (!_controller.isClosed) _controller.add(entry);
  }

  void clear() {
    _entries.clear();
  }
}

void zlog(String message) {
  ProtocolLog.instance.add(message);
  if (zremoteLogEnabled) {
    // ignore: avoid_print
    print('[zremote] $message');
  }
}
