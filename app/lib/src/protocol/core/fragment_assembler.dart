/// Shared fragment assembly for the two transport layers that receive
/// base64-fragmented, CRC32-checked byte messages: the acknowledged rpc-frame
/// transport (keyed by `messageSeq`) and the V4 topic wire frames (keyed by
/// `logicalFrameId`).
///
/// This type only does the mechanical part — fragment bookkeeping, base64
/// decode, concatenation, and stale-assembly expiry. Validation (CRC32,
/// declared byte counts, geometry limits) and the fault policy (degrade vs
/// silent drop) stay with the caller, because the two layers treat failures
/// differently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'crc32.dart';

/// Outcome of feeding one fragment.
sealed class FragmentResult {
  const FragmentResult();
}

/// The message is complete; [bytes] are the concatenated fragments.
class FragmentCompleted extends FragmentResult {
  final Uint8List bytes;
  const FragmentCompleted(this.bytes);
}

/// The message is incomplete or this was a duplicate fragment — wait for
/// more.
class FragmentPending extends FragmentResult {
  const FragmentPending();
}

/// The fragment was malformed (bad geometry, undecodable base64) and was
/// dropped without touching the assembly.
class FragmentRejected extends FragmentResult {
  const FragmentRejected();
}

class FragmentAssembler<K> {
  final Duration timeout;
  final void Function(K key)? onExpired;
  final DateTime Function() _now;

  FragmentAssembler({
    this.timeout = const Duration(seconds: 30),
    this.onExpired,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Map<K, _FragmentAssembly> _assemblies = {};
  Timer? _sweepTimer;

  /// Feeds one fragment of a message identified by [key]. The first fragment
  /// determines the assembly's fragment count.
  FragmentResult accept({
    required K key,
    required int fragmentIndex,
    required int fragmentCount,
    required String dataBase64,
  }) {
    if (fragmentCount < 1 ||
        fragmentIndex < 0 ||
        fragmentIndex >= fragmentCount) {
      return const FragmentRejected();
    }
    final assembly = _assemblies.putIfAbsent(
      key,
      () => _FragmentAssembly(fragmentCount, _now()),
    );
    if (fragmentIndex >= assembly.fragments.length ||
        assembly.fragments[fragmentIndex] != null) {
      return const FragmentPending(); // duplicate or out-of-range fragment
    }
    final Uint8List chunk;
    try {
      chunk = base64Decode(dataBase64);
    } catch (_) {
      return const FragmentRejected();
    }
    assembly.fragments[fragmentIndex] = chunk;
    assembly.receivedCount++;
    _startSweep();
    if (assembly.receivedCount < fragmentCount) {
      return const FragmentPending();
    }
    _assemblies.remove(key);
    return FragmentCompleted(_concat(assembly.fragments));
  }

  /// Drops assemblies older than [timeout], invoking [onExpired] for each.
  void expireStale([DateTime? now]) {
    final t = now ?? _now();
    final expired = <K>[];
    _assemblies.removeWhere((key, a) {
      if (t.difference(a.createdAt) > timeout) {
        expired.add(key);
        return true;
      }
      return false;
    });
    for (final key in expired) {
      onExpired?.call(key);
    }
  }

  void _startSweep() {
    _sweepTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      expireStale();
    });
  }

  Uint8List _concat(List<Uint8List?> fragments) {
    var total = 0;
    for (final f in fragments) {
      total += f!.length;
    }
    final out = Uint8List(total);
    var offset = 0;
    for (final f in fragments) {
      out.setRange(offset, offset + f!.length, f);
      offset += f.length;
    }
    return out;
  }

  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _assemblies.clear();
  }
}

class _FragmentAssembly {
  final DateTime createdAt;
  final List<Uint8List?> fragments;
  int receivedCount = 0;

  _FragmentAssembly(int count, this.createdAt)
    : fragments = List.filled(count, null);
}

/// Utility shared by both callers: verifies the declared whole-message CRC32.
/// Returns true when [checksum] (`{algorithm: "crc32", value: "…"}`) matches
/// [bytes].
bool crc32Matches(Object? checksum, Uint8List bytes) {
  if (checksum is! Map || checksum['value'] is! String) return false;
  return crc32Hex(bytes) == checksum['value'];
}
