/// Credential and message types for the relay WebSocket protocol
/// (`wss://zcode.z.ai/ws`).
library;

import 'dart:convert';

/// A pairing credential extracted from the desktop's QR URL:
/// `https://zcode.z.ai/remote/v4?sid=..&hash=..&t=..&mid=..&name=..&app_version=..`
class PairingCredential {
  final String deviceSid;
  final String passHash; // base64(sha256(password)), from the `hash` param
  final int timestamp; // `t` param, millis
  final String? deviceMid; // `mid` param
  final String? deviceName; // `name` param
  final String? appVersion; // `app_version` param

  const PairingCredential({
    required this.deviceSid,
    required this.passHash,
    required this.timestamp,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
  });

  static PairingCredential? fromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final sid = uri.queryParameters['sid'];
    final hash = uri.queryParameters['hash'];
    final t = uri.queryParameters['t'];
    if (sid == null || sid.isEmpty || hash == null || hash.isEmpty) return null;
    final ts = int.tryParse(t ?? '');
    if (ts == null) return null;
    return PairingCredential(
      deviceSid: sid,
      passHash: hash,
      timestamp: ts,
      deviceMid: uri.queryParameters['mid'],
      deviceName: uri.queryParameters['name'],
      appVersion: uri.queryParameters['app_version'],
    );
  }

  String get displayName => deviceName ?? deviceSid;
}

/// Relay message envelope: every relay frame is JSON with a `type` field.
sealed class RelayMessage {
  const RelayMessage();
  Map<String, Object?> toJson();
}

class AuthInit extends RelayMessage {
  final String role; // "terminal" | "device"
  final String deviceSid;
  final Map<String, String> meta;
  final int clientTs;
  const AuthInit({
    required this.role,
    required this.deviceSid,
    required this.meta,
    required this.clientTs,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': 'auth_init',
        'role': role,
        'device_sid': deviceSid,
        'meta': meta,
        'client_ts': clientTs,
      };
}

class AuthChallenge extends RelayMessage {
  final String nonce;
  const AuthChallenge(this.nonce);
  @override
  Map<String, Object?> toJson() => {'type': 'auth_challenge', 'nonce': nonce};
}

class AuthResponse extends RelayMessage {
  final String deviceSid;
  final String proof;
  final int clientTs;
  const AuthResponse({
    required this.deviceSid,
    required this.proof,
    required this.clientTs,
  });
  @override
  Map<String, Object?> toJson() => {
        'type': 'auth_response',
        'device_sid': deviceSid,
        'proof': proof,
        'client_ts': clientTs,
      };
}

class AuthAck extends RelayMessage {
  final String pairStatus; // "waiting" | "matched"
  const AuthAck(this.pairStatus);
  @override
  Map<String, Object?> toJson() => {'type': 'auth_ack', 'pair_status': pairStatus};
}

class PairStatusQuery extends RelayMessage {
  final String deviceSid;
  final int clientTs;
  const PairStatusQuery(this.deviceSid, this.clientTs);
  @override
  Map<String, Object?> toJson() => {
        'type': 'pair_status_query',
        'device_sid': deviceSid,
        'client_ts': clientTs,
      };
}

class PairStatusAck extends RelayMessage {
  final String pairStatus;
  const PairStatusAck(this.pairStatus);
  @override
  Map<String, Object?> toJson() => {'type': 'pair_status_ack', 'pair_status': pairStatus};
}

/// Application payload carried in a `data` frame.
class DataMessage extends RelayMessage {
  final Map<String, Object?> payload;
  final int clientTs;
  final int? serverTs;
  const DataMessage({required this.payload, required this.clientTs, this.serverTs});
  @override
  Map<String, Object?> toJson() => {
        'type': 'data',
        'payload': payload,
        'client_ts': clientTs,
        if (serverTs != null) 'server_ts': serverTs,
      };
}

class RelayError extends RelayMessage {
  final String code;
  final String message;
  const RelayError(this.code, this.message);
  @override
  Map<String, Object?> toJson() => {'type': 'error', 'code': code, 'message': message};
}

/// Parses an incoming relay frame.
RelayMessage? parseRelayMessage(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final type = decoded['type'];
  switch (type) {
    case 'auth_challenge':
      final nonce = decoded['nonce'];
      return nonce is String ? AuthChallenge(nonce) : null;
    case 'auth_ack':
      final s = decoded['pair_status'];
      return s is String ? AuthAck(s) : null;
    case 'pair_status_ack':
      final s = decoded['pair_status'];
      return s is String ? PairStatusAck(s) : null;
    case 'data':
      final payload = decoded['payload'];
      final clientTs = decoded['client_ts'];
      if (payload is! Map<String, Object?>) return null;
      return DataMessage(
        payload: payload,
        clientTs: clientTs is int ? clientTs : 0,
        serverTs: decoded['server_ts'] is int ? decoded['server_ts'] as int : null,
      );
    case 'error':
      final code = decoded['code'];
      final message = decoded['message'];
      return RelayError(code is String ? code : 'unknown', message is String ? message : '');
    default:
      return null;
  }
}

/// Well-known relay error codes.
class RelayErrorCode {
  static const kicked = 'KICKED';
  static const authFailed = 'AUTH_FAILED';
  static const internal = 'INTERNAL';
  static const wrongParam = 'WRONG_PARAM';
  static const deviceOffline = 'DEVICE_OFFLINE';
}

/// WebSocket close codes the relay uses to signal session state.
class RelayCloseCode {
  static const sessionNotFound = 4004;
  static const sessionConflict = 4009;
  static const desktopDisconnected = 4010;
  static const sessionExpired = 4011;
  static const workspaceClosed = 4012;
  static const invalidMobileConnection = 4013;
}
