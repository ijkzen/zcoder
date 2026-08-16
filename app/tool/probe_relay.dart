/// Probe: connect to the relay as a terminal and print every server frame.
/// Run with `dart run tool/probe_relay.dart "<qr-url>"`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zcode_remote/src/protocol/relay/relay_client.dart'
    show calculateProof, relayWsUrl;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/probe_relay.dart "<qr-url>"');
    exit(1);
  }
  final uri = Uri.parse(args.first);
  final sid = uri.queryParameters['sid'];
  final hash = uri.queryParameters['hash'];
  final mid = uri.queryParameters['mid'];
  final t = uri.queryParameters['t'];
  stderr.writeln('sid=$sid t=$t mid=$mid');
  if (sid == null || hash == null) {
    stderr.writeln('missing sid/hash');
    exit(1);
  }

  final ws = await WebSocket.connect('$relayWsUrl?mid=${mid ?? ''}',
      headers: {'X-Device-ID': mid ?? ''});
  stderr.writeln('connected');

  void send(Map<String, Object?> m) => ws.add(jsonEncode(m));
  final now = DateTime.now().millisecondsSinceEpoch;

  ws.listen((raw) {
    stderr.writeln('>>> $raw');
    final msg = raw is String ? jsonDecode(raw) : null;
    if (msg is Map<String, Object?> && msg['type'] == 'auth_challenge') {
      final nonce = msg['nonce'] as String;
      send({
        'type': 'auth_response',
        'device_sid': sid,
        'proof': calculateProof(hash, nonce, 'terminal', sid),
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
      stderr.writeln('<<< auth_response sent');
    }
  }, onDone: () {
    stderr.writeln('socket closed');
    exit(0);
  }, onError: (e) {
    stderr.writeln('socket error: $e');
    exit(1);
  });

  send({
    'type': 'auth_init',
    'role': 'terminal',
    'device_sid': sid,
    'meta': {'platform': 'android', 'version': '3.4.0', 'name': 'probe'},
    'client_ts': now,
  });
  stderr.writeln('<<< auth_init sent');

  await Future<void>.delayed(const Duration(seconds: 30));
  stderr.writeln('timeout, closing');
  await ws.close();
}
