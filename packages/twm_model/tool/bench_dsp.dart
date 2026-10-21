// Timing of the DSP blocks used for every acquired record (live spectrum,
// on-line analysis). dart run tool/bench_dsp.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

Float64List sig(int n, double fs) => Float64List.fromList([
  for (var i = 0; i < n; i++)
    7.07 * math.sin(2 * math.pi * 50 * i / fs) + 0.07 * math.sin(2 * math.pi * 150 * i / fs + 0.3),
]);

void time(String name, void Function() f) {
  final sw = Stopwatch()..start();
  f();
  print('${name.padRight(34)} ${sw.elapsedMilliseconds} ms');
}

void main() {
  for (final n in [10000, 1 << 20, 2000000, 1 << 21, 10000000]) {
    final fs = n.toDouble(); // 1 s record
    final x = sig(n, fs);
    print('--- n = $n');
    time('window coefficients (hann)', () => WindowType.hann.coefficients(n));
    time('Spectrum.of (hann)', () => Spectrum.of(x, fs, window: WindowType.hann));
    time('HarmonicAnalysis.of (20 harm.)', () => HarmonicAnalysis.of(x, fs, harmonics: 20));
  }
}
