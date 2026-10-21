import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';

/// The live monitor must show a still picture: every frame starts at the
/// same phase of the signal (rising crossing), whatever the packet sizes.
void main() {
  DataPacket sine(int from, int n, double fs, double f, double a, double ph, {double noise = 0, math.Random? rnd}) {
    final s = Int32List(n * 2);
    for (var i = 0; i < n; i++) {
      final t = (from + i) / fs;
      final v = a * math.sin(2 * math.pi * f * t + ph) + (noise > 0 ? (rnd!.nextDouble() - 0.5) * noise : 0);
      s[2 * i] = (v * 1e6).round(); // 1 uV codes
      s[2 * i + 1] = (0.5 * v * 1e6).round();
    }
    return DataPacket(s, 2, from);
  }

  test('frames start at the same phase (rising crossing) for any packet sizes', () {
    const fs = 10000.0, f = 50.0, a = 7.0;
    final rnd = math.Random(3);
    for (final ph in [0.0, 1.0, 2.5, -2.0]) {
      final m = LiveMonitor(channels: 2, window: 400);
      var pos = 0;
      for (var k = 0; k < 40; k++) {
        final n = 37 + rnd.nextInt(900);
        m.add(sine(pos, n, fs, f, a, ph, noise: 0.01, rnd: rnd));
        pos += n;
        final fr = m.frame(const [1e-6, 1e-6], const [0, 0], 1 / fs)!;
        if (m.available < 800) continue;
        expect(fr.triggered, isTrue);
        expect(fr.channels.first.length, 400);
        // phase of the first point equals 2*pi*f*x0 (x0 = time after the crossing)
        final t0 = math.asin((fr.channels.first.first / a).clamp(-1.0, 1.0)) / (2 * math.pi * f);
        expect(t0, closeTo(fr.x0, 5e-6), reason: 'ph=$ph frame $k');
        expect(fr.channels.first[1], greaterThan(fr.channels.first.first)); // rising
      }
    }
  });

  test('DC input: not triggered, newest window shown', () {
    final m = LiveMonitor(channels: 2, window: 100);
    m.add(DataPacket(Int32List(2 * 500)..fillRange(0, 1000, 42), 2, 0));
    final fr = m.frame(const [1, 1], const [0, 0], 1e-3)!;
    expect(fr.triggered, isFalse);
    expect(fr.channels.first.every((v) => v == 42), isTrue);
  });

  test('long window is sent as a min/max envelope of maxPoints', () {
    const fs = 2e6;
    final m = LiveMonitor(channels: 2, window: 160000, maxPoints: 2000);
    var pos = 0;
    for (var k = 0; k < 4; k++) {
      m.add(sine(pos, 100000, fs, 50, 1, 0.3));
      pos += 100000;
    }
    final fr = m.frame(const [1e-6, 1e-6], const [0, 0], 1 / fs)!;
    expect(fr.channels.first.length, lessThanOrEqualTo(2000));
    expect(fr.span, closeTo(0.08, 1e-9));
    expect(fr.channels.first.reduce(math.max), closeTo(1, 1e-3));
  });
}
