/// Layer 1 — relay WebSocket client: connects to `wss://zcode.z.ai/ws`,
/// performs the terminal auth handshake (sid + hash proof), keeps the pairing
/// alive with heartbeats, reconnects with exponential backoff, and forwards
/// application payloads. See docs/protocol/01-relay-transport.md.
library;

import '../zlog.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'relay_frame.dart';

const String relayWsUrl = 'wss://zcode.z.ai/ws';
const int heartbeatIntervalMs = 10000;
const int heartbeatTimeoutMs = 30000;

enum RelayState { connecting, authenticating, paired, reconnecting, closed }

enum RelayFailureReason {
  relayUnavailable,
  authFailed,
  sessionExpired,
  sessionConflict,
  desktopOffline,
  kicked,
  other,
}

/// Maps a relay `error.code` to a failure reason.
RelayFailureReason mapRelayErrorCode(String code) {
  switch (code) {
    case RelayErrorCode.authFailed:
      return RelayFailureReason.authFailed;
    case RelayErrorCode.deviceOffline:
      return RelayFailureReason.desktopOffline;
    case RelayErrorCode.wrongParam:
      return RelayFailureReason.sessionExpired;
    case RelayErrorCode.kicked:
      return RelayFailureReason.kicked;
    default:
      return RelayFailureReason.other;
  }
}

/// Bounded FIFO for outbound app payloads while the relay is not `matched`.
/// New payloads are dropped once full (the oldest keep their turn).
class OutboundQueue {
  OutboundQueue(this.maxSize);
  final int maxSize;
  final List<Map<String, Object?>> _items = [];

  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  void add(Map<String, Object?> payload) {
    if (_items.length < maxSize) _items.add(payload);
  }

  /// Removes and returns everything queued, in order.
  List<Map<String, Object?>> takeAll() {
    if (_items.isEmpty) return const [];
    final items = List<Map<String, Object?>>.from(_items);
    _items.clear();
    return items;
  }
}

class RelayFailure {
  final RelayFailureReason reason;
  final String message;
  const RelayFailure(this.reason, this.message);
}

/// HMAC proof for the relay auth challenge.
///
/// Both roles use the same message layout — `nonce|role|sid` — per the
/// desktop's `calculateProof(passHash, nonce, role, sid)` =
/// `HMAC-SHA256(passHash, "${nonce}|${role}|${sid}")` (base64url, unpadded).
/// (ADR-0001's older `sid|nonce|role` wording is wrong; see
/// docs/protocol/07-flutter-app-audit.md finding 8.)
String calculateProof(
  String passHash,
  String nonce,
  String entity,
  String deviceSid,
) {
  final hmac = Hmac(sha256, utf8.encode(passHash));
  final digest = hmac.convert(utf8.encode('$nonce|$entity|$deviceSid'));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

class RelayClient {
  final PairingCredential credential;
  final String appVersion;
  final String clientName;

  RelayClient({
    required this.credential,
    this.appVersion = '3.4.0',
    this.clientName = 'zcode-remote-flutter',
  });

  // sync: true — consumers (BridgeManager._onRelayState, _waitForRelayReady)
  // must see state transitions in the same microtask; an async broadcast
  // would let a late subscriber miss the `matched` event entirely.
  final _stateController = StreamController<RelayState>.broadcast(sync: true);
  final _payloadController = StreamController<Map<String, Object?>>.broadcast();
  final _failureController = StreamController<RelayFailure>.broadcast();
  final _closedController = StreamController<void>.broadcast();

  Stream<RelayState> get stateStream => _stateController.stream;
  Stream<Map<String, Object?>> get payloadStream => _payloadController.stream;
  Stream<RelayFailure> get failureStream => _failureController.stream;
  Stream<void> get closedStream => _closedController.stream;

  RelayState _state = RelayState.closed;
  RelayState get state => _state;

  WebSocket? _socket;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _userClosed = false;

  void _setState(RelayState s) {
    _state = s;
    if (!_disposed) _stateController.add(s);
  }

  Future<void> connect() async {
    _userClosed = false;
    await _openSocket();
  }

  Future<void> _openSocket() async {
    _setState(
      _reconnectAttempt == 0 ? RelayState.connecting : RelayState.reconnecting,
    );
    final uri = Uri.parse('$relayWsUrl?mid=${credential.deviceMid ?? ''}');
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: {'X-Device-ID': credential.deviceMid ?? ''},
      );
      _socket = socket;
      _reconnectAttempt = 0;
      socket.listen(
        _onRawMessage,
        onDone: _onSocketClosed,
        onError: _onSocketError,
      );
      zlog(
        '[zremote] relay connected, sending auth_init (sid=${credential.deviceSid})',
      );
      _send(
        AuthInit(
          role: 'terminal',
          deviceSid: credential.deviceSid,
          meta: {
            'platform': 'android',
            'version': appVersion,
            'name': clientName,
          },
          clientTs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _setState(RelayState.authenticating);
    } on SocketException catch (e) {
      _emitFailure(
        RelayFailure(RelayFailureReason.relayUnavailable, e.message),
      );
      _scheduleReconnect();
    } on WebSocketException catch (e) {
      _emitFailure(
        RelayFailure(RelayFailureReason.relayUnavailable, e.message),
      );
      _scheduleReconnect();
    }
  }

  void _onRawMessage(dynamic raw) {
    if (raw is! String) return;
    final msg = parseRelayMessage(raw);
    if (msg == null) return;
    switch (msg) {
      case AuthChallenge(:final nonce):
        zlog('[zremote] auth_challenge received, sending proof');
        _send(
          AuthResponse(
            deviceSid: credential.deviceSid,
            proof: calculateProof(
              credential.passHash,
              nonce,
              'terminal',
              credential.deviceSid,
            ),
            clientTs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case AuthAck(:final pairStatus):
        zlog('[zremote] auth_ack pair_status=$pairStatus');
        if (pairStatus == 'matched') {
          _cancelWaitingTimeout();
          _setState(RelayState.paired);
          _startHeartbeat();
          _flushOutboundQueue();
        } else {
          // Desktop offline: hold the connection and let the relay match us
          // with a pair_status_ack once the desktop comes back. Re-sending
          // auth_init while waiting gets WRONG_PARAM from the relay.
          _startWaitingTimeout();
        }
      case PairStatusAck(:final pairStatus):
        zlog('[zremote] pair_status_ack pair_status=$pairStatus');
        if (pairStatus == 'matched' && _state != RelayState.paired) {
          _cancelWaitingTimeout();
          _setState(RelayState.paired);
          _startHeartbeat();
          _flushOutboundQueue();
        }
        _resetHeartbeatTimeout();
      case DataMessage(:final payload):
        if (!_disposed) _payloadController.add(payload);
      case RelayError(:final code, :final message):
        zlog('[zremote] relay error: code=$code message=$message');
        _emitFailure(RelayFailure(mapRelayErrorCode(code), message));
        if (code == RelayErrorCode.authFailed ||
            code == RelayErrorCode.kicked) {
          // Fatal: wrong credentials or kicked off — do not auto-reconnect.
          _userClosed = true;
          _setState(RelayState.closed);
          _socket?.close();
        }
      default:
        break;
    }
  }

  Timer? _waitingTimer;

  /// If the relay never matches us (desktop never came online), rebuild the
  /// connection so auth starts fresh — the relay may have dropped our
  /// waiting session.
  void _startWaitingTimeout() {
    _waitingTimer?.cancel();
    _waitingTimer = Timer(const Duration(seconds: 60), () {
      zlog('[zremote] waiting for desktop timed out, reconnecting');
      _waitingTimer = null;
      _socket?.close();
    });
  }

  void _cancelWaitingTimeout() {
    _waitingTimer?.cancel();
    _waitingTimer = null;
  }

  void _emitFailure(RelayFailure failure) {
    if (!_disposed && !_failureController.isClosed) {
      _failureController.add(failure);
    }
  }

  void _onSocketClosed() {
    _stopHeartbeat();
    _cancelWaitingTimeout();
    final closeCode = _socket?.closeCode;
    final closeReason = _socket?.closeReason;
    _socket = null;
    if (_userClosed || _disposed) {
      _setState(RelayState.closed);
      if (!_disposed) _closedController.add(null);
      return;
    }
    // Report why the link died so the UI can notify the user.
    final failure = _failureForCloseCode(closeCode, closeReason);
    if (failure != null) {
      _emitFailure(failure);
    }
    _setState(RelayState.reconnecting);
    _scheduleReconnect();
  }

  RelayFailure? _failureForCloseCode(int? closeCode, String? closeReason) {
    switch (closeCode) {
      case RelayCloseCode.sessionNotFound:
        return RelayFailure(
          RelayFailureReason.sessionExpired,
          closeReason ?? '会话不存在，请重新扫码配对',
        );
      case RelayCloseCode.sessionConflict:
        return RelayFailure(
          RelayFailureReason.sessionConflict,
          closeReason ?? '同一时间只允许一个手机控制端',
        );
      case RelayCloseCode.desktopDisconnected:
        return RelayFailure(
          RelayFailureReason.desktopOffline,
          closeReason ?? '桌面端已断开',
        );
      case RelayCloseCode.sessionExpired:
        return RelayFailure(
          RelayFailureReason.sessionExpired,
          closeReason ?? '远程控制会话已过期，请重新扫码',
        );
      case RelayCloseCode.workspaceClosed:
        return RelayFailure(RelayFailureReason.other, closeReason ?? '工作区已关闭');
      default:
        return RelayFailure(RelayFailureReason.other, closeReason ?? '连接已断开');
    }
  }

  void _onSocketError(Object error) {
    _emitFailure(RelayFailure(RelayFailureReason.other, error.toString()));
  }

  void _scheduleReconnect() {
    if (_userClosed || _disposed) return;
    final delay = _reconnectAttempt == 0
        ? 500
        : (500 * (1 << _reconnectAttempt)).clamp(0, 10000);
    _reconnectAttempt++;
    Timer(Duration(milliseconds: delay), () {
      if (!_userClosed && !_disposed) _openSocket();
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(milliseconds: heartbeatIntervalMs),
      (_) {
        _send(
          PairStatusQuery(
            credential.deviceSid,
            DateTime.now().millisecondsSinceEpoch,
          ),
        );
        _heartbeatTimeoutTimer?.cancel();
        _heartbeatTimeoutTimer = Timer(
          const Duration(milliseconds: heartbeatTimeoutMs),
          () {
            // No pair_status_ack in time — the link is stale; force reconnect.
            _socket?.close();
          },
        );
      },
    );
  }

  void _resetHeartbeatTimeout() {
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
  }

  /// Outbound data payloads are queued while unpaired (connecting / waiting /
  /// reconnecting) and flushed once the relay reports `matched` — otherwise
  /// requests sent during a reconnect window vanish into a dead socket and
  /// the caller hangs until timeout.
  static const int maxOutboundQueue = 100;
  final OutboundQueue _outboundQueue = OutboundQueue(maxOutboundQueue);

  /// Sends an application payload as a relay `data` frame (layer 2+).
  void sendPayload(Map<String, Object?> payload) {
    if (_state != RelayState.paired || _socket == null) {
      zlog(
        '[zremote] queued payload (state=$_state): ${payload['zcode_type']}',
      );
      _outboundQueue.add(payload);
      return;
    }
    _send(
      DataMessage(
        payload: payload,
        clientTs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _flushOutboundQueue() {
    final queued = _outboundQueue.takeAll();
    if (queued.isEmpty) return;
    zlog('[zremote] flushing ${queued.length} queued payload(s)');
    for (final payload in queued) {
      _send(
        DataMessage(
          payload: payload,
          clientTs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  void _send(RelayMessage message) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode(message.toJson()));
    } catch (_) {
      // Socket is gone; the close handler will drive reconnection.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _userClosed = true;
    _stopHeartbeat();
    _cancelWaitingTimeout();
    await _socket?.close();
    await _stateController.close();
    await _payloadController.close();
    await _failureController.close();
    await _closedController.close();
  }
}
