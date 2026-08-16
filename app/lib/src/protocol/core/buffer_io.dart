/// Growable byte writer and cursor-based reader mirroring the `mc`/`ale`/
/// `pc` helpers in the ZCode desktop protocol code.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'varint.dart' as v;

class ByteWriter {
  final List<Uint8List> _parts = [];
  int _length = 0;

  int get length => _length;

  void write(Uint8List bytes) {
    _parts.add(bytes);
    _length += bytes.length;
  }

  void writeByte(int b) => write(Uint8List.fromList([b]));

  void writeVarint(int value) {
    final buf = Uint8List(v.varintLength(value));
    v.writeVarint(buf, 0, value);
    write(buf);
  }

  Uint8List toBytes() {
    final out = Uint8List(_length);
    var offset = 0;
    for (final p in _parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }
}

class ByteReader {
  final Uint8List bytes;
  int pos = 0;

  ByteReader(this.bytes);

  int get remaining => bytes.length - pos;

  Uint8List read(int n) {
    final out = Uint8List.sublistView(bytes, pos, pos + n);
    pos += n;
    return out;
  }

  int readByte() => bytes[pos++];

  int readVarint() {
    final (value, consumed) = v.readVarint(bytes, pos);
    pos += consumed;
    return value;
  }

  String readString() {
    final n = readVarint();
    return utf8.decode(read(n));
  }
}

/// Big-endian u32 helpers for the 13-byte RPC frame header.
void writeU32BE(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xFF;
  bytes[offset + 1] = (value >> 16) & 0xFF;
  bytes[offset + 2] = (value >> 8) & 0xFF;
  bytes[offset + 3] = value & 0xFF;
}

int readU32BE(Uint8List bytes, int offset) =>
    ((bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3]) &
    0xFFFFFFFF;
