import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/rpc/channel_client.dart';
import 'package:zcode_remote/src/protocol/core/crc32.dart';
import 'package:zcode_remote/src/protocol/core/varint.dart';
import 'package:zcode_remote/src/protocol/relay/relay_client.dart';
import 'package:zcode_remote/src/protocol/relay/relay_frame.dart';
import 'package:zcode_remote/src/protocol/topics/wire_frame.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';
import 'package:zcode_remote/src/protocol/payload/app_payload.dart';
import 'package:zcode_remote/src/protocol/services/services.dart';
import 'package:zcode_remote/src/protocol/transport/rpc_frame_transport.dart';
import 'package:zcode_remote/src/protocol/limits.dart';

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

    test('relay error codes map to failure reasons', () {
      expect(mapRelayErrorCode(RelayErrorCode.kicked), RelayFailureReason.kicked);
      expect(mapRelayErrorCode(RelayErrorCode.authFailed), RelayFailureReason.authFailed);
      expect(mapRelayErrorCode(RelayErrorCode.deviceOffline), RelayFailureReason.desktopOffline);
      expect(mapRelayErrorCode(RelayErrorCode.wrongParam), RelayFailureReason.sessionExpired);
      expect(mapRelayErrorCode('UNKNOWN_FUTURE_CODE'), RelayFailureReason.other);
    });
  });

  group('outbound queue', () {
    test('buffers in order and flushes all at once', () {
      final q = OutboundQueue(100);
      expect(q.isEmpty, isTrue);
      q.add({'zcode_type': 'a'});
      q.add({'zcode_type': 'b'});
      final all = q.takeAll();
      expect(all.map((p) => p['zcode_type']), ['a', 'b']);
      expect(q.isEmpty, isTrue);
      expect(q.takeAll(), isEmpty);
    });

    test('drops new payloads once full (oldest keep their turn)', () {
      final q = OutboundQueue(2);
      q.add({'zcode_type': 'a'});
      q.add({'zcode_type': 'b'});
      q.add({'zcode_type': 'c'});
      expect(q.length, 2);
      expect(q.takeAll().map((p) => p['zcode_type']), ['a', 'b']);
    });
  });

  group('binary rpc', () {
    test('request encoding: raw body, no socket header', () async {
      final sent = <Uint8List>[];
      final serverFrames = StreamController<Uint8List>.broadcast();
      final client = ChannelClient(serverFrames.stream, sent.add);
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
      final client = ChannelClient(serverFrames.stream, sent.add);
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
      final client = ChannelClient(serverFrames.stream, sent.add);
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
      final client = ChannelClient(serverFrames.stream, sent.add);
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

  group('app payload codec', () {
    test('parses workspace-list-response', () {
      final payload = parseAppPayload({
        'zcode_type': 'workspace-list-response',
        'requestId': 'r1',
        'success': true,
        'result': {
          'workspaces': [
            {'workspacePath': '/a', 'label': 'a', 'kind': 'local'}
          ],
          'tasks': [
            {'taskId': 't1', 'title': 'T', 'workspacePath': '/a', 'workspaceLabel': 'a', 'workspaceKind': 'local', 'createdAt': 1, 'updatedAt': 2}
          ],
          'activeWorkspaceKey': '/a',
        },
      });
      expect(payload, isA<WorkspaceListResponse>());
      final list = payload as WorkspaceListResponse;
      expect(list.requestId, 'r1');
      expect(list.data.tasks!.single['taskId'], 't1');
      expect(list.data.activeWorkspaceKey, '/a');
    });

    test('parses bridge identity fields', () {
      final ready = parseAppPayload({
        'zcode_type': 'workspace-bridge-ready',
        'requestId': 'r2',
        'bridgeSessionId': 'bs1',
        'bridgeGeneration': 3,
        'bridge': {'bridgeSessionId': 'bs1', 'kind': 'local', 'workspaceKey': '/a'},
      });
      expect(ready, isA<WorkspaceBridgeReady>());
      final b = ready as WorkspaceBridgeReady;
      expect(b.identity.bridgeSessionId, 'bs1');
      expect(b.identity.bridgeGeneration, 3);
      expect(b.identity.matches({'bridgeSessionId': 'bs1', 'bridgeGeneration': 3}), isTrue);
      expect(b.identity.matches({'bridgeSessionId': 'other'}), isFalse);
    });

    test('rpc payloads pass through raw', () {
      final frame = parseAppPayload({'zcode_type': 'rpc-frame', 'bridgeSessionId': 'bs1', 'seq': 1});
      expect(frame, isA<RpcTransportPayload>());
      expect((frame as RpcTransportPayload).isAck, isFalse);
    });

    test('mobile view state includes required updatedAt', () {
      final payload = mobileViewStateUpdate(
        activeWorkspaceKey: '/a',
        deviceInfo: mobileDeviceInfo(platform: 'android', version: '1', name: 'n'),
      );
      final viewState = payload['viewState'] as Map<String, Object?>;
      final deviceInfo = payload['deviceInfo'] as Map<String, Object?>;
      expect(viewState['updatedAt'], isA<int>());
      expect(deviceInfo['updatedAt'], isA<int>());
    });
  });

  group('rpc frame transport', () {
    test('delivers assembled messages and acks them', () async {
      final sent = <Map<String, Object?>>[];
      final messages = <Uint8List>[];
      final transport = RpcFrameTransport(
        sendPayload: sent.add,
        identity: const BridgeIdentity(bridgeSessionId: 'bs1', bridgeGeneration: 1),
      );
      transport.messageStream.listen(messages.add);

      final body = utf8.encode('hello world');
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bs1',
        'bridgeGeneration': 1,
        'seq': 1,
        'messageSeq': 7,
        'fragmentIndex': 0,
        'fragmentCount': 2,
        'messageBytes': body.length,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
        'dataBase64': base64Encode(body.sublist(0, 5)),
      });
      expect(messages, isEmpty, reason: 'waiting for second fragment');
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bs1',
        'bridgeGeneration': 1,
        'seq': 2,
        'messageSeq': 7,
        'fragmentIndex': 1,
        'fragmentCount': 2,
        'messageBytes': body.length,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
        'dataBase64': base64Encode(body.sublist(5)),
      });
      await Future<void>.delayed(Duration.zero);
      expect(utf8.decode(messages.single), 'hello world');
      expect(sent.single['zcode_type'], 'rpc-frame-ack');
      expect(sent.single['ackMessageSeq'], 7);
      await transport.dispose();
    });

    test('duplicate messages are re-acked then dropped', () async {
      final sent = <Map<String, Object?>>[];
      final messages = <Uint8List>[];
      final transport = RpcFrameTransport(
        sendPayload: sent.add,
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      transport.messageStream.listen(messages.add);
      final body = utf8.encode('x');
      Map<String, Object?> frame(int seq) => {
            'zcode_type': 'rpc-frame',
            'bridgeSessionId': 'bs1',
            'seq': seq,
            'messageSeq': 1,
            'fragmentIndex': 0,
            'fragmentCount': 1,
            'messageBytes': 1,
            'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
            'dataBase64': base64Encode(body),
          };
      transport.acceptPayload(frame(1));
      transport.acceptPayload(frame(1)); // replay after a missed ack
      await Future<void>.delayed(Duration.zero);
      expect(messages, hasLength(1), reason: 'delivered exactly once');
      expect(sent.where((p) => p['zcode_type'] == 'rpc-frame-ack'), hasLength(2),
          reason: 'but re-acked for the replay');
      await transport.dispose();
    });

    test('frames from a foreign bridge identity are dropped', () async {
      final messages = <Uint8List>[];
      final transport = RpcFrameTransport(
        sendPayload: (_) {},
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      transport.messageStream.listen(messages.add);
      final body = utf8.encode('x');
      final accepted = transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'STALE',
        'seq': 1,
        'messageSeq': 1,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'messageBytes': 1,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
        'dataBase64': base64Encode(body),
      });
      expect(accepted, isFalse);
      expect(messages, isEmpty);
      await transport.dispose();
    });

    test('outbound messages replay until acked', () async {
      final sent = <Map<String, Object?>>[];
      final transport = RpcFrameTransport(
        sendPayload: sent.add,
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      transport.sendMessage(utf8.encode('one'));
      transport.sendMessage(utf8.encode('two'));
      final firstRound = sent.where((p) => p['zcode_type'] == 'rpc-frame').length;
      expect(firstRound, 2);

      // Relay dropped everything — reconnect replays both from fragment 0.
      sent.clear();
      transport.replayUnacked();
      expect(sent.where((p) => p['zcode_type'] == 'rpc-frame').length, 2);
      expect(sent.first['messageSeq'], 1);

      // Cumulative ack for message 1 releases only it.
      transport.acceptPayload({
        'zcode_type': 'rpc-frame-ack',
        'bridgeSessionId': 'bs1',
        'ackMessageSeq': 1,
      });
      sent.clear();
      transport.replayUnacked();
      expect(sent.where((p) => p['zcode_type'] == 'rpc-frame').length, 1);
      expect(sent.first['messageSeq'], 2);
      await transport.dispose();
    });

    test('acking an unsent messageSeq degrades the transport', () async {
      final degraded = <String>[];
      final transport = RpcFrameTransport(
        sendPayload: (_) {},
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      transport.degradedStream.listen(degraded.add);
      transport.acceptPayload({
        'zcode_type': 'rpc-frame-ack',
        'bridgeSessionId': 'bs1',
        'ackMessageSeq': 9, // nothing was ever sent
      });
      await Future<void>.delayed(Duration.zero);
      expect(degraded, [RpcFrameFault.futureAck]);
      await transport.dispose();
    });

    test('fragments stay under the 1 MiB envelope limit (512 KiB raw)', () async {
      final sent = <Map<String, Object?>>[];
      final transport = RpcFrameTransport(
        sendPayload: sent.add,
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      // 600 KiB message -> 2 fragments (512 KiB + 88 KiB); at the old 1 MiB
      // raw chunk size this produced a single ~1.37 MiB base64 envelope that
      // violates the desktop's `dataBase64 <= 1 MiB` schema refine.
      final message = Uint8List(600 * 1024);
      transport.sendMessage(message);
      final frames = sent.where((p) => p['zcode_type'] == 'rpc-frame').toList();
      expect(frames, hasLength(2));
      expect(frames[0]['fragmentCount'], 2);
      expect(frames[0]['messageBytes'], message.length);
      for (final frame in frames) {
        expect(
          frame['dataBase64'] as String,
          hasLength(lessThanOrEqualTo(ProtocolLimits.maxPhysicalFrameBytes)),
        );
        expect(
          jsonEncode(frame).length,
          lessThanOrEqualTo(ProtocolLimits.maxPhysicalFrameBytes),
        );
      }
      await transport.dispose();
    });
  });

  group('topic wire frames', () {
    test('complete frames pass the inner topic frame through', () {
      final assembler = WireFrameAssembler();
      final inner = assembler.accept({
        'wireVersion': 3,
        'kind': 'complete',
        'deliveryKind': 'online',
        'logicalFrameId': 'lf1',
        'logicalFrameOrdinal': 1,
        'topic': 'conversation/s1',
        'subscriptionId': 'sub1',
        'frame': {
          'topic': 'conversation/s1',
          'subscriptionId': 'sub1',
          'fromSeq': 0,
          'toSeq': 5,
          'payload': {'kind': 'snapshot', 'snapshot': {'logEpoch': 'e1'}},
        },
      });
      expect(inner, isNotNull);
      expect(inner!.deliveryKind, 'online');
      expect(inner.logicalFrameOrdinal, 1);
      final frame =
          TopicFrame.fromMap(inner.frame, deliveryKind: inner.deliveryKind);
      expect(frame!.topic, 'conversation/s1');
      expect(frame.isSnapshot, isTrue);
      expect(frame.snapshot!['logEpoch'], 'e1');
      expect(frame.deliveryKind, 'online');
    });

    test('fragments reassemble by logicalFrameId with crc check', () {
      final assembler = WireFrameAssembler();
      final innerJson = utf8.encode(jsonEncode({
        'topic': 'conversation/s1',
        'subscriptionId': 'sub1',
        'fromSeq': 5,
        'toSeq': 6,
        'payload': {'kind': 'deltas', 'deltas': [{'op': 'row.appended'}]},
      }));
      final a = innerJson.sublist(0, 4);
      final b = innerJson.sublist(4);
      expect(assembler.accept({
        'wireVersion': 3,
        'kind': 'fragment',
        'logicalFrameId': 'lf2',
        'topic': 'conversation/s1',
        'subscriptionId': 'sub1',
        'fragmentIndex': 0,
        'fragmentCount': 2,
        'logicalBytes': innerJson.length,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(innerJson)},
        'dataBase64': base64Encode(a),
      }), isNull);
      final inner = assembler.accept({
        'wireVersion': 3,
        'kind': 'fragment',
        'logicalFrameId': 'lf2',
        'topic': 'conversation/s1',
        'subscriptionId': 'sub1',
        'fragmentIndex': 1,
        'fragmentCount': 2,
        'logicalBytes': innerJson.length,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(innerJson)},
        'dataBase64': base64Encode(b),
      });
      expect(inner, isNotNull);
      final frame =
          TopicFrame.fromMap(inner!.frame, deliveryKind: inner.deliveryKind);
      final deltas = frame!.deltas;
      expect((deltas!.single as Map<Object?, Object?>)['op'], 'row.appended');
      assembler.dispose();
    });

    test('crc mismatch drops the logical frame', () {
      final assembler = WireFrameAssembler();
      final innerJson = utf8.encode('{"topic":"conversation/s1"}');
      expect(assembler.accept({
        'kind': 'fragment',
        'logicalFrameId': 'lf3',
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'checksum': {'algorithm': 'crc32', 'value': 'deadbeef'},
        'dataBase64': base64Encode(innerJson),
      }), isNull);
      assembler.dispose();
    });
  });

  group('int32 sign extension', () {
    test('negative int32 roundtrips through tag 6', () async {
      final sent = <Uint8List>[];
      final serverFrames = StreamController<Uint8List>.broadcast();
      final client = ChannelClient(serverFrames.stream, sent.add);
      client.start();
      await _sendInitialize(serverFrames);
      await client.whenInitialized;
      final future = client.requestPromise('ch', 'm');
      await Future<void>.delayed(Duration.zero);
      final body = sent.single;
      final (_, header) = _readValue(body, 0);
      final id = (header as List<Object?>)[1] as int;
      serverFrames.add(_frame(_encodeValues([MsgType.promiseSuccess, id, '', ''], -5)));
      expect(await future, -5);
      await serverFrames.close();
    });
  });


  group('rpc transport faults (second pass)', () {
    test('fragmentCount beyond the 64 limit degrades the transport', () async {
      final degraded = <String>[];
      final transport = RpcFrameTransport(
        sendPayload: (_) {},
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      transport.degradedStream.listen(degraded.add);
      final body = utf8.encode('x');
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bs1',
        'seq': 1,
        'messageSeq': 1,
        'fragmentIndex': 0,
        'fragmentCount': 65,
        'messageBytes': 1,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
        'dataBase64': base64Encode(body),
      });
      await Future<void>.delayed(Duration.zero);
      expect(degraded, [RpcFrameFault.invalidPayload]);
      await transport.dispose();
    });

    test('stale inbound assembly degrades with assemblyTimeout', () async {
      var now = DateTime(2026, 1, 1, 12);
      final degraded = <String>[];
      final transport = RpcFrameTransport(
        sendPayload: (_) {},
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
        now: () => now,
      );
      transport.degradedStream.listen(degraded.add);
      final body = utf8.encode('hello world');
      transport.acceptPayload({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'bs1',
        'seq': 1,
        'messageSeq': 1,
        'fragmentIndex': 0,
        'fragmentCount': 2,
        'messageBytes': body.length,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
        'dataBase64': base64Encode(body.sublist(0, 5)),
      });
      // Fragment never completes; advance past the 30 s assembly timeout.
      now = now.add(const Duration(seconds: 31));
      transport.expireStaleAssemblies();
      await Future<void>.delayed(Duration.zero);
      expect(degraded, [RpcFrameFault.assemblyTimeout]);
      await transport.dispose();
    });

    test('unacked outbound beyond the 45 s replay grace degrades', () async {
      var now = DateTime(2026, 1, 1, 12);
      final degraded = <String>[];
      final transport = RpcFrameTransport(
        sendPayload: (_) {},
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
        now: () => now,
      );
      transport.degradedStream.listen(degraded.add);
      transport.sendMessage(utf8.encode('one'));
      now = now.add(const Duration(seconds: 46));
      transport.checkReplayGrace();
      await Future<void>.delayed(Duration.zero);
      expect(degraded, [RpcFrameFault.replayGraceExceeded]);
      expect(transport.isDegraded, isTrue);
      await transport.dispose();
    });

    test('oversized send throws without degrading the bridge', () async {
      final degraded = <String>[];
      final sent = <Map<String, Object?>>[];
      final transport = RpcFrameTransport(
        sendPayload: sent.add,
        identity: const BridgeIdentity(bridgeSessionId: 'bs1'),
      );
      transport.degradedStream.listen(degraded.add);
      expect(
        () => transport.sendMessage(Uint8List(ProtocolLimits.maxMessageBytes + 1)),
        throwsA(isA<RpcTransportException>()),
      );
      expect(transport.isDegraded, isFalse);
      // The bridge still works afterwards.
      transport.sendMessage(utf8.encode('still alive'));
      expect(sent.where((p) => p['zcode_type'] == 'rpc-frame'), hasLength(1));
      await transport.dispose();
    });
  });

  group('topic wire frames (second pass)', () {
    test('unknown wireVersion is dropped', () {
      final assembler = WireFrameAssembler();
      expect(assembler.accept({
        'wireVersion': 99,
        'kind': 'complete',
        'frame': {'topic': 'conversation/s1'},
      }), isNull);
      assembler.dispose();
    });

    test('deliveryKind survives fragment reassembly', () {
      final assembler = WireFrameAssembler();
      final innerJson = utf8.encode(jsonEncode({
        'topic': 'conversation/s1',
        'subscriptionId': 'sub1',
        'fromSeq': 1,
        'toSeq': 2,
        'payload': {'kind': 'deltas', 'deltas': []},
      }));
      final result = assembler.accept({
        'wireVersion': 3,
        'kind': 'fragment',
        'deliveryKind': 'recovery',
        'logicalFrameId': 'lf4',
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'logicalBytes': innerJson.length,
        'checksum': {'algorithm': 'crc32', 'value': crc32Hex(innerJson)},
        'dataBase64': base64Encode(innerJson),
      });
      expect(result, isNotNull);
      expect(result!.deliveryKind, 'recovery');
      assembler.dispose();
    });
  });

  group('workspace keys', () {
    test('remote workspace keys use identity, not path', () {
      final workspace = Workspace.fromJson({
        'workspacePath': '/remote/proj',
        'workspaceIdentity': 'ssh:myserver:/proj',
        'label': 'p',
        'kind': 'remote',
      });
      expect(workspace.workspaceKey, 'ssh:myserver:/proj');
    });

    test('mergedEntries dedups by workspace key across tasks and workspaces',
        () {
      final data = WorkspaceListData.fromResult({
        'workspaces': [
          {'workspacePath': '/a', 'label': 'a', 'kind': 'local'},
          {'workspacePath': '/b', 'label': 'b', 'kind': 'local'},
        ],
        'tasks': [
          {
            'taskId': 't1',
            'title': 'T',
            'workspacePath': '/a',
            'workspaceLabel': 'a',
            'workspaceKind': 'local',
            'createdAt': 1,
            'updatedAt': 2,
          },
        ],
      })!;
      final merged = data.mergedEntries;
      expect(merged, hasLength(2)); // /a deduped, /b kept
      expect(merged.first['taskId'], 't1');
    });

    test('mergedEntries keeps every task of the same workspace', () {
      // Several sessions of one project share its workspacePath — dedup by
      // key must NOT collapse them into a single entry.
      final data = WorkspaceListData.fromResult({
        'workspaces': [
          {'workspacePath': '/a', 'label': 'a', 'kind': 'local'},
        ],
        'tasks': [
          {
            'taskId': 't1',
            'title': 'One',
            'workspacePath': '/a',
            'workspaceLabel': 'a',
            'workspaceKind': 'local',
          },
          {
            'taskId': 't2',
            'title': 'Two',
            'workspacePath': '/a',
            'workspaceLabel': 'a',
            'workspaceKind': 'local',
          },
          {
            'taskId': 't3',
            'title': 'Three',
            'workspacePath': '/a',
            'workspaceLabel': 'a',
            'workspaceKind': 'local',
          },
        ],
      })!;
      final merged = data.mergedEntries;
      expect(merged, hasLength(3));
      expect(merged.map((e) => e['taskId']), ['t1', 't2', 't3']);
    });

    test('mergedEntries keeps remote workspace and task entries apart by key',
        () {
      final data = WorkspaceListData.fromResult({
        'workspaces': [
          {
            'workspacePath': '/remote/proj',
            'workspaceIdentity': 'ssh:srv:/proj',
            'label': 'p',
            'kind': 'remote',
          },
        ],
        'tasks': [
          {
            'taskId': 't1',
            'title': 'T',
            'workspacePath': '/remote/proj',
            'workspaceIdentity': 'ssh:srv:/proj',
            'workspaceLabel': 'p',
            'workspaceKind': 'remote',
            'createdAt': 1,
            'updatedAt': 2,
          },
        ],
      })!;
      expect(data.mergedEntries, hasLength(1));
    });

    test('task entries parse pinned / unreadAt / archived flags', () {
      final data = WorkspaceListData.fromResult({
        'tasks': [
          {
            'taskId': 't1',
            'title': 'Pinned',
            'workspacePath': '/a',
            'workspaceLabel': 'a',
            'workspaceKind': 'local',
            'pinned': true,
            'unreadAt': 123456789,
          },
          {
            'taskId': 't2',
            'title': 'Plain',
            'workspacePath': '/b',
            'workspaceLabel': 'b',
            'workspaceKind': 'local',
          },
          {
            'taskId': 't3',
            'title': 'Archived',
            'workspacePath': '/c',
            'workspaceLabel': 'c',
            'workspaceKind': 'local',
            'archived': true,
          },
        ],
      })!;
      final tasks = [
        for (final entry in data.mergedEntries)
          Workspace.fromJson(entry.cast<String, Object?>())
      ];
      expect(tasks, hasLength(3));
      final pinned = tasks.firstWhere((w) => w.taskId == 't1');
      expect(pinned.pinned, isTrue);
      expect(pinned.unreadAt, 123456789);
      expect(pinned.archived, isFalse);
      final plain = tasks.firstWhere((w) => w.taskId == 't2');
      expect(plain.pinned, isFalse);
      expect(plain.unreadAt, isNull);
      final archived = tasks.firstWhere((w) => w.taskId == 't3');
      expect(archived.archived, isTrue);
      expect(archived.pinned, isFalse);
    });
  });

  group('workspace prep & skills models', () {
    test('parseWorkspacePrep config options and slash commands', () {
      final prep = WorkspacePrep.fromJson({
        'configOptions': [
          {
            'id': 'mode',
            'name': '协作模式',
            'category': 'mode',
            'type': 'select',
            'currentValue': 'build',
            'options': [
              {'value': 'build', 'name': 'Build'},
              {'value': 'plan', 'name': 'Plan'},
            ],
          },
        ],
        'slashCommands': [
          {'name': 'compact', 'description': '压缩上下文', 'source': 'builtin'},
          {
            'name': 'review',
            'description': '代码评审',
            'inputHint': '提交范围',
            'source': 'custom',
          },
        ],
      });
      expect(prep.option('mode'), isNotNull);
      expect(prep.option('mode')!.options.map((o) => o.value),
          ['build', 'plan']);
      expect(prep.option('mode')!.currentValue, 'build');
      expect(prep.slashCommands, hasLength(2));
      expect(prep.slashCommands.first.name, 'compact');
      expect(prep.slashCommands.first.source, 'builtin');
      expect(prep.slashCommands[1].inputHint, '提交范围');
    });

    test('skill entries parse with defaults', () {
      final skills = [
        for (final raw in [
          {
            'id': 's1',
            'name': 'review',
            'path': '/skills/review',
            'scope': 'workspace',
            'description': 'code review',
          },
          {'id': 's2', 'name': 'x', 'path': '/x', 'enabled': false},
        ])
          SkillEntry.fromJson(raw.cast<String, Object?>())
      ];
      expect(skills[0].name, 'review');
      expect(skills[0].description, 'code review');
      expect(skills[0].enabled, isTrue);
      expect(skills[1].enabled, isFalse);
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
    // JS writes the unsigned representation of int32 values.
    _encVarint(out, v < 0 ? v & 0xFFFFFFFF : v);
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
