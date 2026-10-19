import 'dart:convert';
import 'dart:typed_data';

import 'visa_io.dart';

class InstrumentException implements Exception {
  final String message;
  InstrumentException(this.message);
  @override
  String toString() => message;
}

/// Message based instrument session (GPIB, USB-TMC, LAN, serial).
/// Implemented by [VisaIo] (NI-VISA via FFI) and by instrument emulators
/// (resources starting with `SIM::`) used for tests and demo mode.
abstract class InstrumentIo {
  String get resource;

  /// I/O timeout [s].
  double timeout = 10;

  Future<void> write(String cmd) => writeBytes(Uint8List.fromList(latin1.encode(cmd.endsWith('\n') ? cmd : '$cmd\n')));

  Future<void> writeBytes(Uint8List data);

  /// Reads up to [max] bytes; stops at END/termination character when
  /// [term] is true.
  Future<Uint8List> readBytes(int max, {bool term = true});

  /// Reads exactly [n] bytes (binary transfers).
  Future<Uint8List> readExactly(int n) async {
    final b = BytesBuilder(copy: false);
    while (b.length < n) {
      final chunk = await readBytes(n - b.length, term: false);
      if (chunk.isEmpty) throw InstrumentException('$resource: timeout reading binary data');
      b.add(chunk);
    }
    return b.takeBytes();
  }

  /// Reads a text line (response terminated by LF/END).
  Future<String> readLine() async {
    final b = await readBytes(65536);
    return latin1.decode(b).trim();
  }

  Future<String> query(String cmd) async {
    await write(cmd);
    return readLine();
  }

  Future<double> queryNumber(String cmd) async {
    final r = await query(cmd);
    final v = double.tryParse(r.split(',').first.trim());
    if (v == null) throw InstrumentException('$resource: unexpected response to "$cmd": "$r"');
    return v;
  }

  /// Reads IEEE 488.2 definite length block (#<n><len><data>).
  Future<Uint8List> readBlock() async {
    final h = await readExactly(2);
    if (h[0] != 0x23) throw InstrumentException('$resource: binary block expected');
    final nd = h[1] - 0x30;
    final len = int.parse(latin1.decode(await readExactly(nd)));
    final d = await readExactly(len);
    // swallow terminating LF if any
    final saved = timeout;
    try {
      timeout = 0.05;
      await readBytes(1);
    } catch (_) {
    } finally {
      timeout = saved;
    }
    return d;
  }

  /// Device clear (aborts pending operation).
  Future<void> clear();

  /// Serial port control lines (multiplexer driver).
  Future<void> setControlLines({bool? dtr, bool? rts}) async =>
      throw InstrumentException('$resource: control lines not supported');

  /// Returns instrument to local control (GPIB GTL) if supported.
  Future<void> local() async {}

  Future<void> close();
}

typedef IoFactory = Future<InstrumentIo> Function(String resource);

/// Opens instrument sessions; `SIM::<model>::<n>` opens an emulator.
class InstrumentIoFactory {
  static final Map<String, IoFactory> _emulators = {};

  static void registerEmulator(String model, IoFactory f) => _emulators[model.toUpperCase()] = f;

  static Future<InstrumentIo> open(String resource, {double timeout = 10}) async {
    final r = resource.trim();
    InstrumentIo io;
    if (r.toUpperCase().startsWith('SIM::')) {
      final model = r.split('::')[1].toUpperCase();
      final f = _emulators[model];
      if (f == null) throw InstrumentException('No emulator for "$model" (available: ${_emulators.keys.join(', ')})');
      io = await f(r);
    } else {
      io = await VisaIo.open(r);
    }
    io.timeout = timeout;
    return io;
  }

  static List<String> get emulators => _emulators.keys.toList();
}
