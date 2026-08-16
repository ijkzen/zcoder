import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/bridge/binary_rpc.dart';
import 'package:zcode_remote/src/core/crc32.dart';
import 'package:zcode_remote/src/core/varint.dart';
import 'package:zcode_remote/src/relay/relay_client.dart';
import 'package:zcode_remote/src/relay/relay_types.dart';

void main() {
  group('varint', () {
    test('roundtrip', () {
      for (final value in [0, 1, 127, 128, 300, 16383, 16384, 1048576, 0x7FFFFFFF]) {
        final buf = Uint8List(8);
        final written = writeVarint(buf, 0, value);
        final (read, consumed) = readVarint(buf, 0);
        expect(consumed, written);
        expect(read, value, reason: 'value $value');
      }
    });

    test('matches LEB128 spec examples', () {
      final buf = Uint8List(4);
      expect(writeVarint(buf, 0, 300), 2);
      expect(buf[0], 0xAC);
      expect(buf[1], 0x02);
    });
  });

  group('crc32', () {
    test('known vector (IEEE check value)', () {
      // CRC-32 of "123456789" is 0xCBF43926.
      expect(crc32(utf8.encode('123456789')), 0xCBF43926);
    });

    test('hex format is 8 lowercase hex chars', () {
      expect(crc32Hex(utf8.encode('hello')), hasLength(8));
    });
  });

  group('pairing credential', () {
    test('parses QR url', () {
      final url = 'https://zcode.z.ai/remote/v4'
          '?sid=d_HMTcVF16UELSZdSk2AydE5'
          '&hash=abc%3D%3D'
          '&t=1786504650761'
          '&mid=35f1b029-404c-4901-be9d-8a6d2803d319'
          '&name=MyMac'
          '&app_version=3.4.0';
      final credential = PairingCredential.fromUrl(url);
      expect(credential, isNotNull);
      expect(credential!.deviceSid, 'd_HMTcVF16UELSZdSk2AydE5');
      expect(credential.passHash, 'abc==');
      expect(credential.timestamp, 1786504650761);
      expect(credential.deviceMid, '35f1b029-404c-4901-be9d-8a6d2803d319');
      expect(credential.deviceName, 'MyMac');
      expect(credential.appVersion, '3.4.0');
    });

    test('rejects invalid url', () {
      expect(PairingCredential.fromUrl('https://example.com'), isNull);
      expect(PairingCredential.fromUrl('https://zcode.z.ai/remote/v4?sid=x'), isNull);
      expect(PairingCredential.fromUrl('not a url'), isNull);
    });
  });

  group('relay auth', () {
    test('proof is deterministic and base64url', () {
      // HMAC-SHA256(passHash, "$nonce|terminal|$sid") -> base64url, no padding.
      final passHash = 'QUJDREVGRw==';
      final nonce = 'aGVsbG8=';
      final sid = 'd_test';
      final proof = calculateProof(passHash, nonce, 'terminal', sid);
      expect(proof, isNot(contains('=')));
      expect(proof, isNot(contains('+')));
      expect(proof, isNot(contains('/')));
      // decode with padding restored
      final padded = '$proof${'=' * ((4 - proof.length % 4) % 4)}';
      expect(base64Url.decode(padded).length, 32);
    });

    test('proof matches the relay-verified vector (nonce|terminal|sid)', () {
      // Vector captured from the live relay on 2026-08-16: this exact proof
      // was accepted by wss://zcode.z.ai/ws with pair_status=matched.
      final passHash = 'SGsyCg/ovIYiBAqFG/Qm+Ayh8kc38k7T2XIwC5t1O8c=';
      final nonce = '7RLGMUNwTQVdFKDNxTNtA9Ba';
      final sid = 'd_HMTcVF16UELSZdSk2AydE5';
      expect(
        calculateProof(passHash, nonce, 'terminal', sid),
        'bt0BOI5g2_jEQdm-I6KlUfy_nDxBKCc4nDYxYLJzEvQ',
      );
    });

    test('parses relay frames', () {
      final challenge = parseRelayMessage('{"type":"auth_challenge","nonce":"abcd"}');
      expect(challenge, isA<AuthChallenge>());
      expect((challenge as AuthChallenge).nonce, 'abcd');

      final ack = parseRelayMessage('{"type":"auth_ack","pair_status":"matched"}');
      expect(ack, isA<AuthAck>());
      expect((ack as AuthAck).pairStatus, 'matched');

      final data = parseRelayMessage(
          '{"type":"data","payload":{"zcode_type":"workspace-list-request","requestId":"r1"},"client_ts":123}');
      expect(data, isA<DataMessage>());
      expect((data as DataMessage).payload['zcode_type'], 'workspace-list-request');
    });
  });

  group('binary rpc', () {
    test('request encoding: raw body, no socket header', () async {
      final sent = <Uint8List>[];
      final serverFrames = StreamController<Uint8List>.broadcast();
      final client = BinaryRpcClient(serverFrames.stream, sent.add);
      client.start();
      await _sendInitialize(serverFrames);
      await client.whenInitialized;

      // Fire the call without awaiting it — the server never replies here,
      // we only inspect the outbound frame.
      client.requestPromise('zcode-session', 'helloConversationV4');
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(1));

      // The relay frame IS the body: first byte is the array tag of the
      // [msgType, id, channel, method] header — no 13-byte socket header.
      final body = sent.single;
      expect(body[0], _tagArray);
      final (_, header) = _readValue(body, 0);
      expect(header, isA<List<Object?>>());
      final h = header as List<Object?>;
      expect(h[0], MsgType.promise);
      expect(h[1], isA<int>());
      expect(h[2], 'zcode-session');
      expect(h[3], 'helloConversationV4');
      await serverFrames.close();
    });

    test('response decoding: PromiseSuccess resolves the call', () async {
      final sent = <Uint8List>[];
      final serverFrames = StreamController<Uint8List>.broadcast();
      final client = BinaryRpcClient(serverFrames.stream, sent.add);
      client.start();
      await _sendInitialize(serverFrames);
      await client.whenInitialized;

      final future = client.requestPromise('zcode-session', 'sendConversationCommandV4', {
        'type': 'sendText',
        'text': '你好',
      });
      await Future<void>.delayed(Duration.zero);

      // Decode the request to learn the request id.
      final body = sent.single;
      final (_, header) = _readValue(body, 0);
      final id = (header as List<Object?>)[1] as int;

      // Reply with PromiseSuccess carrying a rich args object.
      final result = {
        'commandId': 'cmd_1',
        'status': 'accepted',
        'nested': {'a': 1},
        'list': [1, 2, 3],
        'bin': Uint8List.fromList([0, 1, 255]),
      };
      final replyBody = _encodeValues([MsgType.promiseSuccess, id, '', ''], result);
      serverFrames.add(_frame(replyBody));

      final resolved = await future;
      expect(resolved, isA<Map<String, Object?>>());
      final map = resolved as Map<String, Object?>;
      expect(map['commandId'], 'cmd_1');
      expect(map['status'], 'accepted');
      expect((map['nested'] as Map)['a'], 1);
      expect(map['list'], [1, 2, 3]);
      expect(map['bin'], isA<Uint8List>());
      expect(map['bin'] as Uint8List, [0, 1, 255]);
      await serverFrames.close();
    });

    test('response decoding: PromiseError rejects with RpcError', () async {
      final sent = <Uint8List>[];
      final serverFrames = StreamController<Uint8List>.broadcast();
      final client = BinaryRpcClient(serverFrames.stream, sent.add);
      client.start();
      await _sendInitialize(serverFrames);
      await client.whenInitialized;

      final future = client.requestPromise('zcode-session', 'x');
      await Future<void>.delayed(Duration.zero);
      final body = sent.single;
      final (_, header) = _readValue(body, 0);
      final id = (header as List<Object?>) [1] as int;

      serverFrames.add(_frame(_encodeValues(
        [MsgType.promiseError, id, '', ''],
        {'name': 'Error', 'message': 'boom', 'code': 'WRONG_PARAM'},
      )));
      await expectLater(future, throwsA(isA<RpcError>()));
      try {
        await future;
      } on RpcError catch (e) {
        expect(e.message, 'boom');
        expect(e.extra['code'], 'WRONG_PARAM');
      }
      await serverFrames.close();
    });

    test('events: EventListen then EventFire streams data', () async {
      final sent = <Uint8List>[];
      final serverFrames = StreamController<Uint8List>.broadcast();
      final client = BinaryRpcClient(serverFrames.stream, sent.add);
      client.start();
      await _sendInitialize(serverFrames);
      await client.whenInitialized;

      final events = client.requestEvent('zcode-session', 'onDynamicConversationFrame');
      final received = <Object?>[];
      final sub = events.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      final body = sent.single;
      final (_, header) = _readValue(body, 0);
      final h = header as List<Object?>;
      expect(h[0], MsgType.eventListen);
      final id = h[1] as int;

      final framePayload = {'kind': 'topic-frame', 'topic': 'conversation/sess_1'};
      serverFrames.add(_frame(_encodeValues([MsgType.eventFire, id, '', ''], framePayload)));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect((received.single as Map)['topic'], 'conversation/sess_1');

      await sub.cancel();
      await serverFrames.close();
    });
  });
}

// ---------- helpers: construct frames the way the desktop does ----------

const _tagUndefined = 0;
const _tagString = 1;
const _tagVsBuffer = 3;
const _tagArray = 4;
const _tagObject = 5;
const _tagInt = 6;

Future<void> _sendInitialize(StreamController<Uint8List> serverFrames) async {
  serverFrames.add(_frame(_encodeValues([MsgType.initialize, 0, '', ''], null)));
}

/// Over the relay each rpc-frame carries the raw body — no 13-byte socket
/// header (that header belongs to the desktop's local SocketProtocol layer).
Uint8List _frame(Uint8List body) => body;

Uint8List _encodeValues(List<Object?> a, Object? b) {
  final out = BytesBuilder();
  _enc(out, a);
  _enc(out, b);
  return out.toBytes();
}

void _enc(BytesBuilder out, Object? v) {
  if (v == null) {
    out.addByte(_tagUndefined);
  } else if (v is String) {
    final b = utf8.encode(v);
    out.addByte(_tagString);
    _encVarint(out, b.length);
    out.add(b);
  } else if (v is Uint8List) {
    out.addByte(_tagVsBuffer);
    _encVarint(out, v.length);
    out.add(v);
  } else if (v is List) {
    out.addByte(_tagArray);
    _encVarint(out, v.length);
    for (final item in v) {
      _enc(out, item);
    }
  } else if (v is int) {
    out.addByte(_tagInt);
    _encVarint(out, v);
  } else {
    final b = utf8.encode(jsonEncode(_jsonSafe(v)));
    out.addByte(_tagObject);
    _encVarint(out, b.length);
    out.add(b);
  }
}

Object? _jsonSafe(Object? v) {
  if (v is Uint8List) {
    return {'__zcode_rpc_nested_uint8array_v1': true, 'base64': base64Encode(v)};
  }
  if (v is List) return v.map(_jsonSafe).toList();
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), _jsonSafe(val)));
  return v;
}

void _encVarint(BytesBuilder out, int v) {
  final buf = Uint8List(8);
  final n = writeVarint(buf, 0, v);
  out.add(Uint8List.sublistView(buf, 0, n));
}

(int, Object?) _readValue(Uint8List bytes, int offset) {
  final tag = bytes[offset];
  switch (tag) {
    case _tagUndefined:
      return (1, null);
    case _tagString:
      final (len, consumed) = readVarint(bytes, offset + 1);
      final end = offset + 1 + consumed + len;
      return (end - offset, utf8.decode(bytes.sublist(offset + 1 + consumed, end)));
    case _tagVsBuffer:
      final (len, consumed) = readVarint(bytes, offset + 1);
      final end = offset + 1 + consumed + len;
      return (end - offset, bytes.sublist(offset + 1 + consumed, end));
    case _tagArray:
      final (count, consumed) = readVarint(bytes, offset + 1);
      final list = <Object?>[];
      var pos = offset + 1 + consumed;
      for (var i = 0; i < count; i++) {
        final (n, value) = _readValue(bytes, pos);
        pos += n;
        list.add(value);
      }
      return (pos - offset, list);
    case _tagObject:
      final (len, consumed) = readVarint(bytes, offset + 1);
      final end = offset + 1 + consumed + len;
      return (end - offset, jsonDecode(utf8.decode(bytes.sublist(offset + 1 + consumed, end))));
    case _tagInt:
      final (value, consumed) = readVarint(bytes, offset + 1);
      return (1 + consumed, value);
    default:
      throw FormatException('unknown tag $tag');
  }
}
