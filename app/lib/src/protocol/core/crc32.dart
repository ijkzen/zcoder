/// CRC-32 (IEEE 802.3, same polynomial as zlib) — used by the rpc-frame
/// checksum in the acknowledged relay protocol.
library;

import 'dart:typed_data';

const int _crc32Poly = 0xEDB88320;

final Uint32List _crc32Table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (_crc32Poly ^ (c >> 1)) : (c >> 1);
    }
    table[i] = c;
  }
  return table;
}

/// Returns the CRC-32 of [bytes] as an unsigned 32-bit integer.
int crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crc32Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// The checksum value formatted as the 8-hex-digit string used on the wire.
String crc32Hex(Uint8List bytes) =>
    crc32(bytes).toRadixString(16).padLeft(8, '0');
