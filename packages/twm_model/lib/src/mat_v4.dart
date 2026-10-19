import 'dart:typed_data';

/// Element precision of a MAT v4 variable (the "P" digit of the type id).
enum MatPrecision {
  float64(0, 8),
  float32(1, 4),
  int32(2, 4),
  int16(3, 2),
  uint16(4, 2),
  uint8(5, 1);

  final int code;
  final int size;
  const MatPrecision(this.code, this.size);

  static MatPrecision fromCode(int c) =>
      values.firstWhere((p) => p.code == c, orElse: () => throw FormatException('MAT v4: unsupported precision $c'));
}

/// One real numeric matrix of a MAT v4 file. Data is stored column-major
/// (as in the file).
class MatVariable {
  final String name;
  final int rows;
  final int cols;
  final MatPrecision precision;
  final TypedData data;

  MatVariable(this.name, this.rows, this.cols, this.precision, this.data);

  num at(int r, int c) => (data as List<num>)[r + c * rows];

  /// Row [r] as doubles, optionally scaled `v*gain + offset`.
  Float64List row(int r, {double gain = 1, double offset = 0, int start = 0, int? end}) {
    final e = end ?? cols;
    final list = data as List<num>;
    final out = Float64List(e - start);
    for (var c = start; c < e; c++) {
      out[c - start] = list[r + c * rows] * gain + offset;
    }
    return out;
  }

  factory MatVariable.float64(String name, int rows, int cols, Float64List colMajor) =>
      MatVariable(name, rows, cols, MatPrecision.float64, colMajor);
}

/// Minimal MAT v4 (Matlab level 4) reader/writer, little endian, real
/// full matrices only. This is the TWM raw record format: variable `y`
/// with one row per channel, one column per sample, integer samples
/// scaled by per-channel gain/offset stored in the session header.
class MatV4 {
  static Uint8List headerBytes(String name, int rows, int cols, MatPrecision p) {
    final nameBytes = [...name.codeUnits, 0];
    final b = ByteData(20);
    b.setInt32(0, p.code * 10, Endian.little); // M=0 (LE), O=0, P, T=0
    b.setInt32(4, rows, Endian.little);
    b.setInt32(8, cols, Endian.little);
    b.setInt32(12, 0, Endian.little);
    b.setInt32(16, nameBytes.length, Endian.little);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...nameBytes]);
  }

  static Uint8List encode(List<MatVariable> vars) {
    final bb = BytesBuilder(copy: false);
    for (final v in vars) {
      bb.add(headerBytes(v.name, v.rows, v.cols, v.precision));
      bb.add(dataBytes(v.data));
    }
    return bb.takeBytes();
  }

  static Uint8List dataBytes(TypedData d) {
    // Host is little endian on all supported platforms (x86/ARM).
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }

  static List<MatVariable> decode(Uint8List bytes, {Set<String>? only}) {
    final out = <MatVariable>[];
    final bd = ByteData.sublistView(bytes);
    var pos = 0;
    while (pos + 20 <= bytes.length) {
      var endian = Endian.little;
      var type = bd.getInt32(pos, Endian.little);
      if (type < 0 || type > 4052) {
        endian = Endian.big;
        type = bd.getInt32(pos, Endian.big);
      }
      final m = type ~/ 1000;
      final p = (type ~/ 10) % 10;
      final t = type % 10;
      final rows = bd.getInt32(pos + 4, endian);
      final cols = bd.getInt32(pos + 8, endian);
      final imag = bd.getInt32(pos + 12, endian);
      final namlen = bd.getInt32(pos + 16, endian);
      if (m > 1 || t != 0 && t != 1) {
        throw FormatException('MAT v4: unsupported type $type');
      }
      final name = String.fromCharCodes(bytes.sublist(pos + 20, pos + 20 + namlen).takeWhile((c) => c != 0));
      pos += 20 + namlen;
      final prec = MatPrecision.fromCode(p);
      final n = rows * cols;
      final len = n * prec.size * (imag != 0 ? 2 : 1);
      if (pos + len > bytes.length) {
        throw const FormatException('MAT v4: truncated file');
      }
      if (only == null || only.contains(name)) {
        out.add(MatVariable(name, rows, cols, prec, _read(bd, pos, n, prec, endian)));
      }
      pos += len;
    }
    return out;
  }

  static TypedData _read(ByteData bd, int pos, int n, MatPrecision p, Endian e) {
    switch (p) {
      case MatPrecision.float64:
        final l = Float64List(n);
        for (var i = 0; i < n; i++) {
          l[i] = bd.getFloat64(pos + i * 8, e);
        }
        return l;
      case MatPrecision.float32:
        final l = Float32List(n);
        for (var i = 0; i < n; i++) {
          l[i] = bd.getFloat32(pos + i * 4, e);
        }
        return l;
      case MatPrecision.int32:
        final l = Int32List(n);
        for (var i = 0; i < n; i++) {
          l[i] = bd.getInt32(pos + i * 4, e);
        }
        return l;
      case MatPrecision.int16:
        final l = Int16List(n);
        for (var i = 0; i < n; i++) {
          l[i] = bd.getInt16(pos + i * 2, e);
        }
        return l;
      case MatPrecision.uint16:
        final l = Uint16List(n);
        for (var i = 0; i < n; i++) {
          l[i] = bd.getUint16(pos + i * 2, e);
        }
        return l;
      case MatPrecision.uint8:
        return Uint8List.fromList(bd.buffer.asUint8List(bd.offsetInBytes + pos, n));
    }
  }
}
