import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import '../digitizer/virtual_digitizer.dart';
import '../store/file_store.dart';

/// Streaming writer of a raw record file (MAT v4, variable `y`, one row
/// per channel). Columns count is patched on [close], so data of any length
/// can be streamed without holding it in memory (needed for streaming
/// digitizers).
class RecordFileWriter {
  final String path;
  final int channels;
  final bool int16;
  final String varName;
  late final StoreSink _f;
  int _cols = 0;

  RecordFileWriter._(this.path, this.channels, this.int16, this.varName);

  static Future<RecordFileWriter> create(
    FileStore store,
    String path,
    int channels, {
    bool int16 = false,
    String varName = 'y',
  }) async {
    final w = RecordFileWriter._(path, channels, int16, varName);
    w._f = await store.openSink(path);
    await w._f.add(MatV4.headerBytes(varName, channels, 0, int16 ? MatPrecision.int16 : MatPrecision.int32));
    return w;
  }

  int get samplesWritten => _cols;

  Future<void> write(DataPacket p) async {
    if (p.channels != channels) {
      throw ArgumentError('Packet channels ${p.channels} != file channels $channels');
    }
    if (int16) {
      final d = Int16List(p.samples.length);
      for (var i = 0; i < d.length; i++) {
        d[i] = p.samples[i];
      }
      await _f.add(d.buffer.asUint8List());
    } else {
      await _f.add(p.samples.buffer.asUint8List(p.samples.offsetInBytes, p.samples.lengthInBytes));
    }
    _cols += p.count;
  }

  Future<void> close() async {
    final b = ByteData(4)..setInt32(0, _cols, Endian.little);
    await _f.writeAt(8, b.buffer.asUint8List());
    await _f.close();
  }
}

/// Reads a record file (whole or decimated) and returns scaled channels.
class RecordFileReader {
  static Future<MatVariable> read(FileStore store, String path, {String varName = 'y'}) async {
    final bytes = await store.readBytes(path);
    final vars = MatV4.decode(bytes, only: {varName});
    if (vars.isEmpty) throw FormatException('Variable "$varName" not found in $path');
    return vars.first;
  }
}
