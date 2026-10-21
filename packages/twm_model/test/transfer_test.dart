import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_model/twm_model.dart';

/// UPS output: 230 V 50 Hz with THD 3 %, an event (interruption / sag) of
/// known start and duration, phase jump after the event, noise.
Float64List ups({
  required double start,
  required double duration,
  double level = 0,
  double jump = 0,
  double fs = 20000,
  double t = 0.3,
  double ph = 0.4,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  final n = (fs * t).round();
  final a = 230 * math.sqrt2;
  final x = Float64List(n);
  for (var i = 0; i < n; i++) {
    final tt = i / fs;
    final k = tt >= start && tt < start + duration ? level : 1.0;
    final p = ph + (tt >= start + duration ? jump : 0);
    final w = 2 * math.pi * 50 * tt;
    final v = a * (math.sin(w + p) + 0.024 * math.sin(3 * (w + p) + 0.2) + 0.015 * math.sin(5 * (w + p) + 1.0));
    x[i] = k * v + (rnd.nextDouble() - 0.5) * 0.2;
  }
  return x;
}

void main() {
  test('interruption 3.7 ms with a 30 deg phase jump', () {
    final r = TransferAnalysis.analyze(ups(start: 0.1013, duration: 0.0037, jump: math.pi / 6), 20000, 50);
    expect(r.detected, isTrue, reason: r.message);
    expect(r.start * 1000, closeTo(101.3, 0.03)); // +-0.5 sample = 25 us
    expect(r.duration * 1000, closeTo(3.7, 0.05));
    expect(r.phaseJump * 180 / math.pi, closeTo(30, 0.5));
    expect(r.depth, lessThan(0.05));
    expect(r.maxDeviation, greaterThan(0.9));
  });

  test('interruption starting exactly at a zero crossing is not detected late', () {
    // sin(w t + 0.4) = 0 at t = (pi - 0.4) / w (falling zero crossing) -> 8.73 ms + periods
    final t0 = (math.pi - 0.4) / (2 * math.pi * 50) + 0.08;
    final r = TransferAnalysis.analyze(ups(start: t0, duration: 0.004), 20000, 50);
    expect(r.detected, isTrue, reason: r.message);
    expect(r.start * 1000, closeTo(t0 * 1000, 0.06));
    expect(r.duration * 1000, closeTo(4.0, 0.12));
  });

  test('sag to 40 % for 20 ms', () {
    final r = TransferAnalysis.analyze(ups(start: 0.1, duration: 0.02, level: 0.4), 20000, 50);
    expect(r.detected, isTrue, reason: r.message);
    expect(r.duration * 1000, closeTo(20, 0.1));
    expect(r.depth, closeTo(0.4, 0.05));
    expect(r.phaseJump.abs(), lessThan(0.01));
  });

  test('steady waveform: no event', () {
    final r = TransferAnalysis.analyze(ups(start: 1, duration: 0), 20000, 50);
    expect(r.detected, isFalse);
    expect(r.message, 'no event');
  });

  test('many random events: duration error < 2 % of 4 ms', () {
    final rnd = math.Random(5);
    var worst = 0.0;
    for (var k = 0; k < 40; k++) {
      final st = 0.06 + rnd.nextDouble() * 0.1, d = 0.002 + rnd.nextDouble() * 0.008;
      final r = TransferAnalysis.analyze(
        ups(start: st, duration: d, jump: (rnd.nextDouble() - 0.5) * 1.5, ph: rnd.nextDouble() * 6, seed: k),
        20000,
        50,
      );
      expect(r.detected, isTrue, reason: r.message);
      worst = math.max(worst, (r.duration - d).abs());
    }
    expect(worst * 1000, lessThan(0.08), reason: 'worst duration error ${worst * 1e3} ms');
  });

  test('phase sweep with 24 bit quantization: duration error never above one sample', () {
    const fs = 20000.0;
    final lsb = 10 / (1 << 23);
    var worst = 0.0;
    for (var k = 0; k < 360; k++) {
      final t0 = k / 360 / 50;
      final x = Float64List(6000);
      for (var i = 0; i < x.length; i++) {
        final tr = i / fs, t = t0 + tr;
        final jump = tr >= 0.1271 ? math.pi / 6 : 0.0;
        var v = 3.25 * math.sin(2 * math.pi * 50 * t + jump) + 0.08 * math.sin(2 * math.pi * 150 * t + 0.3 + 3 * jump);
        if (tr >= 0.1234 && tr < 0.1271) v = 0;
        x[i] = (v / lsb).roundToDouble() * lsb;
      }
      final r = TransferAnalysis.analyze(x, fs, 50.3);
      expect(r.detected, isTrue, reason: 'phase $k deg: ${r.message}');
      worst = math.max(worst, (r.duration - 0.0037).abs());
    }
    expect(worst, lessThanOrEqualTo(1 / fs + 1e-9), reason: 'worst ${worst * 1e6} us');
  });
}
