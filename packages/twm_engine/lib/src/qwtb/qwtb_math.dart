/// Numerical building blocks ported from the QWTB / TWM m-functions so the
/// Dart algorithms reproduce the original results (window definitions,
/// `ampphspectrum`, `td_fft_filter` / `sFreqDep_PG_Comp`).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

int nextPow2(num x) {
  var p = 0;
  while ((1 << p) < x) {
    p++;
  }
  return p;
}

/// QWTB `flattop(N, 10)` = HFT144D, periodic variant (window_coeff periodic:
/// symmetric window of N+1 points without the last one).
Float64List flattop144dPeriodic(int n) {
  const c = [1.0, -1.96760033, 1.57983607, -0.81123644, 0.22583558, -0.02773848, 0.00090360];
  final denorm = 1 / c.fold<double>(0, (s, v) => s + v.abs());
  final w = Float64List(n);
  for (var k = 0; k < n; k++) {
    var v = 0.0;
    for (var j = 0; j < c.length; j++) {
      v += c[j] * denorm * math.cos(2 * math.pi * j * k / n);
    }
    w[k] = v;
  }
  return w;
}

/// Octave signal `blackmanharris(m, 'periodic')`.
Float64List blackmanHarrisPeriodic(int m) {
  final w = Float64List(m);
  for (var k = 0; k < m; k++) {
    final x = 2 * math.pi * k / m;
    w[k] = 0.35875 - 0.48829 * math.cos(x) + 0.14128 * math.cos(2 * x) - 0.01168 * math.cos(3 * x);
  }
  return w;
}

/// `hanning(m)` as shipped with the TWM algorithms (symmetric, with zero end
/// points - differs from the Octave built-in one).
Float64List twmHanning(int m) {
  if (m == 1) return Float64List.fromList([1]);
  final w = Float64List(m);
  for (var k = 0; k < m; k++) {
    w[k] = 0.5 - 0.5 * math.cos(2 * math.pi * k / (m - 1));
  }
  return w;
}

class AmpPhSpectrum {
  final Float64List f;
  final Float64List amp;
  final Float64List ph;
  final Float64List w;
  const AmpPhSpectrum(this.f, this.amp, this.ph, this.w);
}

/// QWTB SP-WFFT `ampphspectrum` with periodic window [w] (null = rect).
AmpPhSpectrum ampPhSpectrum(Float64List y, double fs, Float64List? w) {
  final n = y.length;
  final x = Float64List(n);
  var norm = n.toDouble();
  if (w != null) {
    norm = 0;
    for (var i = 0; i < n; i++) {
      x[i] = y[i] * w[i];
      norm += w[i];
    }
  } else {
    x.setAll(0, y);
  }
  final (re, im) = Fft.transform(x);
  final h = (n / 2 + 0.5).ceil();
  final amp = Float64List(h), ph = Float64List(h), f = Float64List(h);
  for (var k = 0; k < h; k++) {
    // rotation by pi/2 (sine phase reference)
    final r = -im[k], i = re[k];
    amp[k] = 2 * math.sqrt(r * r + i * i) / norm;
    ph[k] = math.atan2(i, r);
    f[k] = fs / n * k;
  }
  amp[0] = re[0] / norm; // imag of rotated DC bin
  ph[0] = 0;
  return AmpPhSpectrum(f, amp, ph, w ?? (Float64List(n)..fillRange(0, n, 1.0)));
}

/// Linear interpolation with constant extrapolation outside [x].
double interpLinear(List<double> x, List<double> y, double xi) {
  if (xi <= x.first) return y.first;
  if (xi >= x.last) return y.last;
  var lo = 0, hi = x.length - 1;
  while (hi - lo > 1) {
    final m = (lo + hi) >> 1;
    if (x[m] > xi) {
      hi = m;
    } else {
      lo = m;
    }
  }
  final t = (xi - x[lo]) / (x[hi] - x[lo]);
  return y[lo] + t * (y[hi] - y[lo]);
}

/// TWM `td_fft_filter`: frequency dependent gain/phase correction by
/// overlapping FFT frames (`sFreqDep_PG_Comp` with `HannFcompMask`).
/// Output is shorter than input (edges of size fft_size/2 cropped) exactly
/// as in the original.
Float64List tdFftFilter(
  Float64List y,
  double fs,
  int fftSize,
  List<double> f,
  List<double> gain,
  List<double> phi, {
  double nyquistFix = 0.02,
}) {
  final half = fftSize ~/ 2;
  final fr = [for (var k = 0; k <= half; k++) k / fftSize * fs];
  final fg = [for (final x in fr) interpLinear(f, gain, x)];
  final fp = [for (final x in fr) interpLinear(f, phi, x)];
  if (nyquistFix > 0) {
    var mw = (nyquistFix * half).round();
    for (var k = 0; k <= mw; k++) {
      fp[fp.length - 1 - mw + k] *= 0.5 + 0.5 * math.cos(k / mw * math.pi);
    }
    mw = 4;
    for (var k = 0; k <= mw; k++) {
      fp[k] *= 0.5 + 0.5 * math.cos((mw - k) / mw * math.pi);
    }
  }
  // complex compensation vector of full FFT size
  final cr = Float64List(fftSize), ci = Float64List(fftSize);
  for (var k = 0; k <= half; k++) {
    cr[k] = fg[k] * math.cos(fp[k]);
    ci[k] = fg[k] * math.sin(fp[k]);
  }
  cr[0] = fg[0];
  ci[0] = 0;
  for (var k = half + 1; k < fftSize; k++) {
    cr[k] = cr[fftSize - k];
    ci[k] = -ci[fftSize - k];
  }
  cr[half] = fg.last * math.cos(fp.last);
  ci[half] = 0;
  final identity = fg.every((g) => g == 1) && fp.every((p) => p == 0);

  // HannFcompMask(N)/2
  final q = fftSize ~/ 4;
  final hw = Float64List(fftSize);
  final hann = twmHanning(q * 2 + 1).sublist(0, q * 2);
  final mean = hann.reduce((a, b) => a + b) / hann.length;
  for (var k = 0; k < q * 2; k++) {
    hw[q + k] = hann[k] / mean / 2;
  }
  final steps = ((y.length - fftSize) / q).ceil();
  final out = <double>[];
  var carry = Float64List(q);
  for (var frame = 1; frame <= steps; frame++) {
    final bs = (frame - 1) * q;
    var uo = Float64List.fromList(y.sublist(bs, bs + fftSize));
    if (!identity) {
      final xr = Float64List.fromList(uo), xi = Float64List(fftSize);
      Fft.radix2(xr, xi);
      for (var k = 0; k < fftSize; k++) {
        final r = xr[k] * cr[k] - xi[k] * ci[k];
        xi[k] = xr[k] * ci[k] + xi[k] * cr[k];
        xr[k] = r;
      }
      xi[half] = 0;
      Fft.radix2(xr, xi, inverse: true);
      uo = xr;
    }
    for (var k = 0; k < fftSize; k++) {
      uo[k] *= hw[k];
    }
    if (frame != 1) {
      for (var k = 0; k < q; k++) {
        out.add(carry[k] + uo[q + k]);
      }
    }
    carry = Float64List.fromList(uo.sublist(2 * q, 3 * q));
  }
  return Float64List.fromList(out);
}
