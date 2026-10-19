import 'dart:typed_data';

import 'emulated_io.dart';

/// Emulator of HP/Agilent/Keysight 3458A in digitizing mode (subset of the
/// command set used by the digitizer driver: PRESET, FUNC, TIMER, APER,
/// SWEEP, NRDGS, TARM, TRIG, MFORMAT/OFORMAT SINT/DINT, ISCALE?, ID?,
/// CALSTR?, TEMP?, ERRSTR?). Readings are output as big endian integers.
class Emu3458a extends EmulatedIo {
  Emu3458a(super.resource);

  String func = 'DCV';
  double range = 10;
  double timer = 1e-4;
  double aper = 1e-6;
  int nrdgs = 1;
  String sampleEvent = 'AUTO';
  String tarm = 'AUTO';
  String trig = 'AUTO';
  String oformat = 'ASCII';
  String mem = 'OFF';
  bool display = true;
  String? error;
  int calibrations = 0;

  bool get sint => oformat == 'SINT';

  /// Integer scale (ISCALE?) for the current range and format.
  double get iscale => sint ? range * 1.2 / 32767 : range * 1.2 / 2147483647;

  void _fail(String m) => error ??= m;

  double _num(String s) => double.parse(s.trim());

  @override
  void command(String c) {
    final u = c.toUpperCase();
    final parts = u.split(RegExp(r'\s+'));
    final head = parts.first;
    final args = parts.length > 1
        ? u.substring(head.length).trim().split(',').map((e) => e.trim()).toList()
        : <String>[];
    switch (head) {
      case 'RESET':
      case 'PRESET':
        func = 'DCV';
        range = 10;
        tarm = (args.isNotEmpty && args.first == 'DIG') ? 'HOLD' : 'AUTO';
        oformat = 'ASCII';
      case 'END':
      case 'DELAY':
      case 'EXTOUT':
      case 'TBUFF':
      case 'AZERO':
      case 'MATH':
      case 'SLOPE':
      case 'LEVEL':
      case 'MFORMAT':
        break;
      case 'DISP':
        display = args.isEmpty || args.first != 'OFF';
      case 'FUNC':
        func = args[0];
        if (args.length > 1) range = _num(args[1]);
        if (!['DCV', 'DSDC', 'DSAC', 'ACV'].contains(func)) _fail('INVALID FUNC $func');
      case 'TIMER':
        timer = _num(args[0]);
        if (timer < 1e-5) _fail('TIMER TOO SHORT');
      case 'APER':
        aper = _num(args[0]);
        if (aper < 500e-9 || aper > 1) _fail('APER OUT OF RANGE');
      case 'SWEEP':
        timer = _num(args[0]);
        nrdgs = _num(args[1]).round();
      case 'NRDGS':
        nrdgs = _num(args[0]).round();
        sampleEvent = args.length > 1 ? args[1] : 'AUTO';
      case 'MEM':
        mem = args.isEmpty ? 'FIFO' : args.first;
      case 'OFORMAT':
        oformat = args.first;
      case 'TRIG':
        trig = args.first;
      case 'TARM':
        tarm = args.first;
        if (tarm == 'SGL') _acquire();
      case 'ID?':
        respond('HP3458A');
      case 'CALSTR?':
        respond('"MY4505309$index"');
      case 'TEMP?':
        respond('${35.5 + index}');
      case 'ISCALE?':
        respond(iscale.toStringAsExponential(9));
      case 'APER?':
        respond(aper.toStringAsExponential(6));
      case 'ERRSTR?':
        respond(error == null ? '0,"NO ERROR"' : '1,"$error"');
        error = null;
      case 'ACAL':
        calibrations++;
      default:
        _fail('UNDEFINED HEADER $head');
    }
  }

  void _acquire() {
    if (oformat != 'SINT' && oformat != 'DINT') {
      _fail('only SINT/DINT digitizing emulated');
      return;
    }
    final n = nrdgs;
    final bd = ByteData(n * (sint ? 2 : 4));
    final sc = iscale;
    for (var i = 0; i < n; i++) {
      // emulated synchronous sampling: all channels sample at the same times
      final v = signal(i * timer);
      final code = (v / sc).round();
      if (sint) {
        bd.setInt16(i * 2, code.clamp(-32768, 32767), Endian.big);
      } else {
        bd.setInt32(i * 4, code, Endian.big);
      }
    }
    respondBytes(bd.buffer.asUint8List());
  }
}
