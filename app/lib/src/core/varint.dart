/// Unsigned LEB128 varint, the same encoding used by the ZCode binary RPC
/// layer (`gc`/`hc` in the desktop protocol code).
library;

import 'dart:typed_data';

/// Number of 7-bit groups needed to encode [value].
int varintLength(int value) {
  if (value == 0) return 1;
  var n = 0;
  var v = value;
  while (v != 0) {
    n++;
    v >>= 7;
  }
  return n;
}

/// Writes [value] as an unsigned LEB128 varint into [bytes] at [offset].
/// Returns the number of bytes written.
int writeVarint(Uint8List bytes, int offset, int value) {
  if (value == 0) {
    bytes[offset] = 0;
    return 1;
  }
  var written = 0;
  var v = value;
  while (v != 0) {
    var b = v & 0x7f;
    v >>= 7;
    if (v > 0) b |= 0x80;
    bytes[offset + written] = b;
    written++;
  }
  return written;
}

/// Reads an unsigned LEB128 varint starting at [offset].
/// Returns the value and the number of bytes consumed.
(int, int) readVarint(Uint8List bytes, int offset) {
  var value = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    final b = bytes[i];
    value |= (b & 0x7f) << shift;
    i++;
    if ((b & 0x80) == 0) break;
    shift += 7;
  }
  return (value, i - offset);
}
