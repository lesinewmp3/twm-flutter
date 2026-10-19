import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_model/twm_model.dart';

Float64List sine(int n, double fs, List<(double f, double a, double ph)> comps, {double dc = 0}) =>
    Float64List.fromList([
      for (var i = 0; i < n; i++)
        dc + comps.fold(0.0, (s, c) => s + c.$2 * math.sin(2 * math.pi * c.$1 * i / fs + c.$3))
    ]);

void main() {
  test('Bluestein FFT equals DFT for odd length', () {
    final x = Float64List.fromList([for (var i = 0; i < 15; i++) math.sin(i * 0.7) + i * 0.1]);
    final (re, im) = Fft.transform(x);
    for (var k = 0; k < 15; k++) {
      var r = 0.0, s = 0.0;
      for (var n = 0; n < 15; n++) {
        r += x[n] * math.cos(-2 * math.pi * k * n / 15);
        s += x[n] * math.sin(-2 * math.pi * k * n / 15);
      }
      expect(re[k], closeTo(r, 1e-9));
      expect(im[k], closeTo(s, 1e-9));
    }
  });

  test('coherent spectrum amplitudes', () {
    final x = sine(1000, 10000, [(50, 2, 0), (150, 0.1, 0.3)], dc: 0.5);
    final sp = Spectrum.of(x, 10000);
    expect(sp.df, 10);
    expect(sp.amp[0], closeTo(0.5, 1e-12));
    expect(sp.amp[5], closeTo(2, 1e-12));
    expect(sp.amp[15], closeTo(0.1, 1e-12));
  });

  test('harmonic analysis non-coherent', () {
    final x = sine(10000, 10000, [(50.3, 1.0, 0.2), (150.9, 0.03, 0)]);
    final h = HarmonicAnalysis.of(x, 10000, harmonics: 5, window: WindowType.hann);
    expect(h.f0, closeTo(50.3, 0.01));
    expect(h.amplitudes[0], closeTo(1.0, 0.01));
    expect(h.amplitudes[2], closeTo(0.03, 0.002));
    expect(h.thd, closeTo(0.03, 0.003));
    expect(h.rms, closeTo(math.sqrt(0.5 + 0.03 * 0.03 / 2), 2e-3));
  });

  test('power', () {
    final u = sine(1000, 10000, [(50, 10, 0)]);
    final i = sine(1000, 10000, [(50, 2, -math.pi / 3)]);
    final p = PowerAnalysis.of(u, i);
    expect(p.p, closeTo(10 * 2 / 2 * 0.5, 1e-9));
    expect(p.pf, closeTo(0.5, 1e-9));
  });

  test('running statistics', () {
    final s = RunningStat(3)
      ..add(1)
      ..add(2)
      ..add(3)
      ..add(4);
    expect(s.values, [2, 3, 4]);
    expect(s.average, 3);
    expect(s.std, closeTo(1, 1e-12));
  });
}
