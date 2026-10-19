import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../io/instrument_io.dart';

/// Base of the instrument emulators: commands are split by `;` and new
/// lines and passed to [command]; responses are queued to the output
/// buffer. Emulators implement the instrument behaviour as described in its
/// manual so the drivers can be tested without hardware (and demo mode).
abstract class EmulatedIo extends InstrumentIo {
  @override
  final String resource;
  final _out = BytesBuilder(copy: true);
  Uint8List _pending = Uint8List(0);
  final log = <String>[];
  bool closed = false;

  EmulatedIo(this.resource);

  /// Index from resource `SIM::MODEL::<n>` (1 based), used to give each
  /// emulated channel different signal.
  int get index => int.tryParse(resource.split('::').length > 2 ? resource.split('::')[2] : '1') ?? 1;

  void respond(String s) => _out.add(latin1.encode('$s\r\n'));
  void respondBytes(Uint8List b) => _out.add(b);

  /// Handles one command (without separators).
  void command(String cmd);

  @override
  Future<void> writeBytes(Uint8List data) async {
    final s = latin1.decode(data);
    for (final c in s.split(RegExp(r'[;\n\r]'))) {
      final t = c.trim();
      if (t.isEmpty) continue;
      log.add(t);
      command(t);
    }
  }

  Uint8List _take() {
    if (_pending.isEmpty) _pending = _out.takeBytes();
    return _pending;
  }

  @override
  Future<Uint8List> readBytes(int max, {bool term = true}) async {
    var buf = _take();
    if (buf.isEmpty) {
      await Future<void>.delayed(Duration(milliseconds: (timeout * 1000).clamp(0, 50).round()));
      buf = _take();
      if (buf.isEmpty) throw InstrumentException('$resource: read timeout');
    }
    var n = math.min(max, buf.length);
    if (term) {
      final lf = buf.indexOf(10);
      if (lf >= 0 && lf < n) n = lf + 1;
    }
    final r = Uint8List.fromList(buf.sublist(0, n));
    _pending = Uint8List.fromList(buf.sublist(n));
    return r;
  }

  @override
  Future<void> clear() async {
    _out.clear();
    _pending = Uint8List(0);
    log.add('<DCL>');
  }

  @override
  Future<void> close() async => closed = true;

  /// Signal used by the emulators: 50 Hz sine with harmonic, channel
  /// dependent amplitude/phase.
  double signal(double t) {
    final a = index == 1 ? 0.7 : 0.35;
    final ph = (index - 1) * 0.3;
    return a * math.sin(2 * math.pi * 50 * t + ph) + 0.01 * a * math.sin(2 * math.pi * 150 * t);
  }
}
