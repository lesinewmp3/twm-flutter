import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'emulated_io.dart';

/// Emulator of Keysight Infiniium DSO (SCPI subset used by the driver).
class EmuDso extends EmulatedIo {
  EmuDso(super.resource);

  double srate = 1e6;
  int points = 1000;
  int source = 1;
  bool done = false;
  final Map<int, double> ranges = {};

  double get yinc => (ranges[source] ?? 8) / 65536;

  @override
  void command(String c) {
    final u = c.toUpperCase().replaceFirst(RegExp(r'^:'), '');
    final sp = u.indexOf(' ');
    final head = sp < 0 ? u : u.substring(0, sp);
    final arg = sp < 0 ? '' : u.substring(sp + 1).trim();
    final m = RegExp(r'^CHAN(?:NEL)?(\d):RANG(?:E)?$').firstMatch(head);
    if (m != null) {
      ranges[int.parse(m.group(1)!)] = double.parse(arg);
      return;
    }
    switch (head) {
      case '*IDN?':
        respond('KEYSIGHT TECHNOLOGIES,DSOS604A,MY00000001,06.40');
      case '*OPC?':
        respond('1');
      case 'ACQUIRE:SRATE:ANALOG':
      case 'ACQ:SRAT:ANAL':
        srate = double.parse(arg);
      case 'ACQUIRE:SRATE:ANALOG?':
        respond(srate.toStringAsExponential(6));
      case 'ACQUIRE:POINTS:ANALOG':
        points = int.parse(arg);
      case 'SINGLE':
        done = true;
      case 'ADER?':
        respond(done ? '1' : '0');
      case 'WAVEFORM:SOURCE':
        source = int.parse(arg.replaceAll(RegExp(r'[^0-9]'), ''));
      case 'WAVEFORM:YINCREMENT?':
        respond(yinc.toStringAsExponential(8));
      case 'WAVEFORM:YORIGIN?':
        respond('0');
      case 'WAVEFORM:XINCREMENT?':
        respond((1 / srate).toStringAsExponential(8));
      case 'WAVEFORM:XORIGIN?':
        respond('-1E-6');
      case 'WAVEFORM:DATA?':
        final bd = ByteData(points * 2);
        for (var i = 0; i < points; i++) {
          final v = (source == 1 ? 0.7 : 0.35) * _sin(i / srate);
          bd.setInt16(i * 2, (v / yinc).round(), Endian.little);
        }
        final len = '${points * 2}';
        respondBytes(Uint8List.fromList([...latin1.encode('#${len.length}$len'), ...bd.buffer.asUint8List(), 10]));
      case 'SYSTEM:ERROR?':
        respond('0,"No error"');
      default:
        break; // configuration commands accepted silently
    }
  }

  static double _sin(double t) => math.sin(2 * math.pi * 50 * t);
}
