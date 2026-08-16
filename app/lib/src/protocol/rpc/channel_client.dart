/// Layer 4 — the binary RPC channel that runs over the acknowledged rpc-frame
/// transport: named channels, promise calls (type 100/201/202/203) and event
/// subscriptions (102/103/204). See docs/protocol/04-binary-rpc-channel.md.
///
/// Bodies are two typed-serialized values: the `[msgType, requestId, channel,
/// method]` array and the `args` value. Serialization uses 1-byte tags and
/// LEB128 varints; int32 negatives travel as unsigned varints and are
/// sign-extended on decode (matching the desktop's JS int32 coercion).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/buffer_io.dart';

/// Request/response message types (protocol-level, not the 13-byte socket
/// header used device-internally).
class MsgType {
  static const promise = 100;
  static const promiseCancel = 101;
  static const eventListen = 102;
  static const eventDispose = 103;
  static const initialize = 200;
  static const promiseSuccess = 201;
  static const promiseError = 202;
  static const promiseErrorObj = 203;
  static const eventFire = 204;
}

// Type tags for the typed value serialization.
class _Tag {
  static const undefined = 0;
  static const string = 1;
  static const buffer = 2;
  static const vsBuffer = 3;
  static const array = 4;
  static const object = 5;
  static const int = 6;
}

const String _nestedUint8Key = '__zcode_rpc_nested_uint8array_v1';
const String _base64Key = 'base64';
const int _int32SignBit = 1 << 31;
const int _int32Range = 1 << 32;

class RpcError implements Exception {
  final String name;
  final String message;
  final String? stack;
  final Map<String, Object?> extra;
  RpcError(this.name, this.message, this.stack, this.extra);
  @override
  String toString() => 'RpcError($name): $message';
}

class RpcChannel {
  final String name;
  final ChannelClient client;
  RpcChannel(this.name, this.client);

  Future<Object?> call(String method, [Object? args]) =>
      client.requestPromise(name, method, args);

  Stream<Object?> listen(String method, [Object? args]) =>
      client.requestEvent(name, method, args);
}

class ChannelClient {
  final Stream<Uint8List> messageStream;
  final void Function(Uint8List frame) frameSender;
  ChannelClient(this.messageStream, this.frameSender);

  final _pending = <int, Completer<Object?>>{};
  final _events = <int, _EventSubscription>{};
  final _controllers = <int, StreamController<Object?>>{};
  final _onInitialize = StreamController<void>.broadcast();

  int _lastRequestId = 0;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  Stream<void> get onInitialize => _onInitialize.stream;

  /// Completes once the device's Initialize frame (type 200) has arrived.
  Future<void> get whenInitialized async {
    if (_initialized) return;
    await _onInitialize.stream.first;
  }

  void start() {
    _subscription = messageStream.listen(_onMessage);
  }

  late final StreamSubscription<Uint8List> _subscription;

  RpcChannel channel(String name) => RpcChannel(name, this);

  Future<Object?> requestPromise(
    String channel,
    String method, [
    Object? args,
  ]) {
    final id = ++_lastRequestId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    // The protocol spreads the args array into the method call, so a single
    // argument must be wrapped: `call(m, x)` -> `service.m(x)`.
    _sendRequest(
      MsgType.promise,
      id,
      channel,
      method,
      args == null ? const [] : [args],
    );
    return completer.future;
  }

  Stream<Object?> requestEvent(String channel, String method, [Object? args]) {
    final id = ++_lastRequestId;
    final controller = StreamController<Object?>.broadcast();
    final sub = _EventSubscription(id, controller);
    _events[id] = sub;
    _controllers[id] = controller;
    _sendRequest(
      MsgType.eventListen,
      id,
      channel,
      method,
      // Event args are delivered to the handler as-is (no spread), unlike
      // promise args which are spread into the method call. Wrapping here
      // (as `[args]`) registers the listener with the wrong value — the host
      // then keys it under a bogus workspaceKey and never routes frames to
      // it (E2E-verified 2026-08-17: zemote/renderer pass the scope map
      // directly and receive frames; zcoder wrapped it and got none).
      args,
    );
    controller.onCancel = () {
      _sendCancelOrDispose(MsgType.eventDispose, id);
      _events.remove(id);
      _controllers.remove(id);
    };
    return controller.stream;
  }

  void _sendRequest(
    int type,
    int id,
    String channel,
    String method,
    Object? args,
  ) {
    if (!_initialized) {
      // The device sends Initialize first; we must not send before that.
      throw StateError('binary rpc not initialized');
    }
    final writer = ByteWriter();
    _serializeValue(writer, [type, id, channel, method]);
    _serializeValue(writer, args);
    frameSender(writer.toBytes());
  }

  void _sendCancelOrDispose(int type, int id) {
    if (!_initialized) return;
    final writer = ByteWriter();
    _serializeValue(writer, [type, id]);
    _serializeValue(writer, null); // undefined
    frameSender(writer.toBytes());
  }

  void _onMessage(Uint8List data) {
    // Over the relay each rpc-frame carries the raw body — the two
    // typed-serialized values — with no 13-byte socket header (that header
    // belongs to the device-internal SocketProtocol layer and is not used on
    // the relay path).
    if (data.isEmpty) return;
    final reader = ByteReader(data);
    final header = _deserializeValue(reader);
    if (header is! List || header.isEmpty) return;
    final type = header[0];
    if (type is! int) return;
    final args = reader.remaining > 0 ? _deserializeValue(reader) : null;

    switch (type) {
      case MsgType.initialize:
        _initialized = true;
        if (!_onInitialize.isClosed) _onInitialize.add(null);
      case MsgType.promiseSuccess:
        final id = header.length > 1 ? header[1] : null;
        if (id is int) {
          final c = _pending.remove(id);
          c?.complete(args);
        }
      case MsgType.promiseError:
        final id = header.length > 1 ? header[1] : null;
        if (id is int) {
          final c = _pending.remove(id);
          if (c != null) {
            final data2 = args is Map<String, Object?>
                ? args
                : <String, Object?>{};
            final extra = Map<String, Object?>.from(data2);
            final name = extra.remove('name')?.toString() ?? 'Error';
            final message = extra.remove('message')?.toString() ?? '';
            final stack = extra.remove('stack');
            c.completeError(
              RpcError(
                name,
                message,
                stack is List ? stack.join('\n') : stack?.toString(),
                extra,
              ),
            );
          }
        }
      case MsgType.promiseErrorObj:
        final id = header.length > 1 ? header[1] : null;
        if (id is int) {
          final c = _pending.remove(id);
          c?.completeError(args ?? 'error');
        }
      case MsgType.eventFire:
        final id = header.length > 1 ? header[1] : null;
        if (id is int) {
          _controllers[id]?.add(args);
        }
    }
  }

  // ---- Typed value serialization ----

  void _serializeValue(ByteWriter w, Object? value) {
    if (value == null) {
      w.writeByte(_Tag.undefined);
    } else if (value is String) {
      final bytes = utf8.encode(value);
      w.writeByte(_Tag.string);
      w.writeVarint(bytes.length);
      w.write(bytes);
    } else if (value is Uint8List) {
      w.writeByte(_Tag.vsBuffer);
      w.writeVarint(value.length);
      w.write(value);
    } else if (value is List) {
      w.writeByte(_Tag.array);
      w.writeVarint(value.length);
      for (final item in value) {
        _serializeValue(w, item);
      }
    } else if (value is int && value >= -2147483648 && value <= 2147483647) {
      w.writeByte(_Tag.int);
      // JS writes the unsigned representation of the int32 value.
      final v = value < 0 ? value & 0xFFFFFFFF : value;
      w.writeVarint(v);
    } else {
      // Everything else (objects, bool, double, int64) goes through JSON.
      final json = jsonEncode(_jsonFriendly(value));
      final bytes = utf8.encode(json);
      w.writeByte(_Tag.object);
      w.writeVarint(bytes.length);
      w.write(bytes);
    }
  }

  Object? _jsonFriendly(Object? value) {
    if (value is Uint8List) {
      return {_nestedUint8Key: true, _base64Key: base64Encode(value)};
    }
    if (value is List) return value.map(_jsonFriendly).toList();
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _jsonFriendly(v)));
    }
    return value;
  }

  Object? _deserializeValue(ByteReader r) {
    if (r.remaining <= 0) return null;
    final tag = r.readByte();
    switch (tag) {
      case _Tag.undefined:
        return null;
      case _Tag.string:
        final n = r.readVarint();
        return utf8.decode(r.read(n));
      case _Tag.buffer:
      case _Tag.vsBuffer:
        final n = r.readVarint();
        return r.read(n);
      case _Tag.array:
        final n = r.readVarint();
        final out = <Object?>[];
        for (var i = 0; i < n; i++) {
          out.add(_deserializeValue(r));
        }
        return out;
      case _Tag.object:
        final n = r.readVarint();
        final raw = utf8.decode(r.read(n));
        return _jsonReviver(jsonDecode(raw));
      case _Tag.int:
        var v = r.readVarint();
        // JS readers sign-extend through int32 coercion; mirror that for
        // values whose bit 31 is set.
        if (v >= _int32SignBit && v < _int32Range) v -= _int32Range;
        return v;
      default:
        throw FormatException('unknown type tag $tag');
    }
  }

  Object? _jsonReviver(Object? value) {
    if (value is Map) {
      if (value.length == 2 &&
          value[_nestedUint8Key] == true &&
          value[_base64Key] is String) {
        return base64Decode(value[_base64Key] as String);
      }
      return value.map((k, v) => MapEntry(k.toString(), _jsonReviver(v)));
    }
    if (value is List) return value.map(_jsonReviver).toList();
    return value;
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('disposed'));
    }
    _pending.clear();
    await _onInitialize.close();
  }
}

class _EventSubscription {
  final int id;
  final StreamController<Object?> controller;
  _EventSubscription(this.id, this.controller);
}
