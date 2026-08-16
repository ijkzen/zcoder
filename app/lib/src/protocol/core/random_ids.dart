/// Cryptographically secure random identifiers for bridge sessions, client
/// ids, and command ids. These appear in protocol messages, so they must not
/// be guessable from timestamps.
library;

import 'dart:math';

final Random _secure = Random.secure();

String _randomToken(int byteCount) {
  final bytes = List<int>.generate(byteCount, (_) => _secure.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Stable client identity for the conversation protocol (`clientId` in
/// clientHello and command envelopes).
String newClientId() => 'zr_${_randomToken(12)}';

/// Bridge session id on the relay (`bridgeSessionId` in rpc-frames).
/// The relay allows `/^[A-Za-z0-9._~-]+$/` for these ids.
String newBridgeSessionId() => 'b_${_randomToken(12)}';

/// Command envelope id (`commandId`).
String newCommandId() => 'cmd_${_randomToken(8)}';
