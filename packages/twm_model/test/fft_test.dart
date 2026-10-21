import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_model/twm_model.dart';

/// Naive DFT, angle from the exact integer (k*j mod n).
(Float64List, Float64List) dft(Float64List xr, Float64List xi) {
  final n = xr.length;
  final re = Float64List(n), im = Float64List(n);
  for (var k = 0; k < n; k++) {
    var sr = 0.0, si = 0.0;
    for (var j = 0; j < n; j++) {
      final a = -2 * math.pi * ((k * j) % n) / n;
      final c = math.cos(a), s = math.sin(a);
      sr += xr[j] * c - xi[j] * s;
      si += xr[j] * s + xi[j] * c;
    }
    re[k] = sr;
    im[k] = si;
  }
  return (re, im);
}

double maxErr(Float64List ar, Float64List ai, Float64List br, Float64List bi) {
  var e = 0.0;
  for (var k = 0; k < ar.length; k++) {
    e = math.max(e, math.max((ar[k] - br[k]).abs(), (ai[k] - bi[k]).abs()));
  }
  return e;
}

void main() {
  final rnd = math.Random(7);
  Float64List rand(int n) => Float64List.fromList([for (var i = 0; i < n; i++) rnd.nextDouble() * 2 - 1]);

  test('complex FFT equals DFT for mixed radix, generic and Bluestein lengths', () {
    for (final n in [
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 25, 27, 30, 32, 45, 49, 60, 61, 64, 96, 100, //
      120, 125, 127, 128, 243, 250, 256, 343, 360, 500, 997, 1000, 1009, 1024, 2000, 2048, 2310, 3001,
    ]) {
      final xr = rand(n), xi = rand(n);
      final (er, ei) = dft(xr, xi);
      final (fr, fi) = Fft.transform(xr, xi);
      expect(maxErr(fr, fi, er, ei), lessThan(1e-12 * n), reason: 'n=$n plan=${Fft.plan(n)}');
      // inverse restores the input
      final (br, bi) = Fft.inverse(fr, fi);
      expect(maxErr(br, bi, xr, xi), lessThan(1e-13 * n), reason: 'inverse n=$n');
    }
  });

  test('real FFT equals the one sided complex FFT', () {
    for (final n in [2, 3, 4, 5, 6, 8, 10, 12, 30, 64, 100, 254, 1000, 1022, 2002, 4096, 10000]) {
      final x = rand(n);
      final (cr, ci) = Fft.transform(x);
      final (rr, ri) = Fft.real(x);
      expect(rr.length, n ~/ 2 + 1);
      expect(
        maxErr(rr, ri, Float64List.sublistView(cr, 0, n ~/ 2 + 1), Float64List.sublistView(ci, 0, n ~/ 2 + 1)),
        lessThan(1e-12 * n),
        reason: 'n=$n',
      );
    }
  });

  test('radix2 in place equals DFT', () {
    for (final n in [2, 4, 8, 64, 256, 1024]) {
      final xr = rand(n), xi = rand(n);
      final (er, ei) = dft(xr, xi);
      final r = Float64List.fromList(xr), i = Float64List.fromList(xi);
      Fft.radix2(r, i);
      expect(maxErr(r, i, er, ei), lessThan(1e-12 * n));
    }
  });

  test('large FFT keeps the exact tone amplitude (rounding grows with log n only)', () {
    for (final n in [1 << 20, 2000000, 3000000]) {
      // tone exactly at bin 50, amplitude 1 -> |X[50]| = n/2
      final x = Float64List(n);
      for (var i = 0; i < n; i++) {
        x[i] = math.sin(2 * math.pi * ((50 * i) % n) / n);
      }
      final (re, im) = Fft.real(x);
      final a = math.sqrt(re[50] * re[50] + im[50] * im[50]) / (n / 2);
      expect((a - 1).abs(), lessThan(1e-12), reason: 'n=$n');
      var leak = 0.0;
      for (var k = 0; k < re.length; k++) {
        if (k != 50) leak = math.max(leak, math.sqrt(re[k] * re[k] + im[k] * im[k]) / (n / 2));
      }
      expect(leak, lessThan(1e-12), reason: 'n=$n');
    }
  });
}
