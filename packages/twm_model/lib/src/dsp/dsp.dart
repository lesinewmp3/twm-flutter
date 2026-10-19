/// Signal processing for the live views and for the on-line analysis of
/// TPQA ("CVI Data Processing", originally NI Advanced Analysis Library).
/// Note: these results are indicative only - validated results come from
/// the QWTB algorithms (same statement as in the TPQA guide).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// FFT of arbitrary length (radix-2 for powers of two, Bluestein otherwise).
class Fft {
  /// In-place complex FFT, [re]/[im] length must be a power of two.
  static void radix2(Float64List re, Float64List im, {bool inverse = false}) {
    final n = re.length;
    if (n <= 1) return;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = 2 * math.pi / len * (inverse ? 1 : -1);
      final wr = math.cos(ang), wi = math.sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        for (var k = 0; k < len ~/ 2; k++) {
          final a = i + k, b = a + len ~/ 2;
          final xr = re[b] * cr - im[b] * ci;
          final xi = re[b] * ci + im[b] * cr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
    if (inverse) {
      for (var i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }

  static int _pow2(int n) {
    var m = 1;
    while (m < n) {
      m <<= 1;
    }
    return m;
  }

  /// Complex FFT of any length. Returns (re, im).
  static (Float64List, Float64List) transform(Float64List xr, [Float64List? xi]) {
    final n = xr.length;
    final im0 = xi ?? Float64List(n);
    if (n & (n - 1) == 0) {
      final re = Float64List.fromList(xr), im = Float64List.fromList(im0);
      radix2(re, im);
      return (re, im);
    }
    // Bluestein chirp-z
    final m = _pow2(2 * n - 1);
    final wr = Float64List(n), wi = Float64List(n);
    for (var k = 0; k < n; k++) {
      final a = math.pi * ((k * k) % (2 * n)) / n;
      wr[k] = math.cos(a);
      wi[k] = -math.sin(a);
    }
    final ar = Float64List(m), ai = Float64List(m);
    for (var k = 0; k < n; k++) {
      ar[k] = xr[k] * wr[k] - im0[k] * wi[k];
      ai[k] = xr[k] * wi[k] + im0[k] * wr[k];
    }
    final br = Float64List(m), bi = Float64List(m);
    br[0] = wr[0];
    bi[0] = -wi[0];
    for (var k = 1; k < n; k++) {
      br[k] = br[m - k] = wr[k];
      bi[k] = bi[m - k] = -wi[k];
    }
    radix2(ar, ai);
    radix2(br, bi);
    for (var k = 0; k < m; k++) {
      final r = ar[k] * br[k] - ai[k] * bi[k];
      ai[k] = ar[k] * bi[k] + ai[k] * br[k];
      ar[k] = r;
    }
    radix2(ar, ai, inverse: true);
    final re = Float64List(n), im = Float64List(n);
    for (var k = 0; k < n; k++) {
      re[k] = ar[k] * wr[k] - ai[k] * wi[k];
      im[k] = ar[k] * wi[k] + ai[k] * wr[k];
    }
    return (re, im);
  }
}

enum WindowType {
  none('None (rectangular)'),
  hann('Hanning'),
  hamming('Hamming'),
  blackman('Blackman'),
  blackmanHarris('Blackman-Harris'),
  flatTop('Flat top');

  final String label;
  const WindowType(this.label);

  Float64List coefficients(int n) {
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      final x = 2 * math.pi * i / n;
      w[i] = switch (this) {
        WindowType.none => 1.0,
        WindowType.hann => 0.5 - 0.5 * math.cos(x),
        WindowType.hamming => 0.54 - 0.46 * math.cos(x),
        WindowType.blackman => 0.42 - 0.5 * math.cos(x) + 0.08 * math.cos(2 * x),
        WindowType.blackmanHarris =>
          0.35875 - 0.48829 * math.cos(x) + 0.14128 * math.cos(2 * x) - 0.01168 * math.cos(3 * x),
        WindowType.flatTop =>
          0.21557895 -
              0.41663158 * math.cos(x) +
              0.277263158 * math.cos(2 * x) -
              0.083578947 * math.cos(3 * x) +
              0.006947368 * math.cos(4 * x),
      };
    }
    return w;
  }
}

/// One sided amplitude spectrum (peak amplitudes), windowed and normalized
/// by the window coherent gain.
class Spectrum {
  final Float64List amp;
  final Float64List phase;
  final double df;
  const Spectrum(this.amp, this.phase, this.df);

  static Spectrum of(Float64List x, double fs, {WindowType window = WindowType.none}) {
    final n = x.length;
    if (n < 2) return Spectrum(Float64List(0), Float64List(0), 0);
    final w = window.coefficients(n);
    var wsum = 0.0;
    final xr = Float64List(n);
    for (var i = 0; i < n; i++) {
      xr[i] = x[i] * w[i];
      wsum += w[i];
    }
    final (re, im) = Fft.transform(xr);
    final h = n ~/ 2 + 1;
    final amp = Float64List(h), ph = Float64List(h);
    for (var k = 0; k < h; k++) {
      final s = (k == 0 || (n.isEven && k == n ~/ 2)) ? 1.0 : 2.0;
      amp[k] = s * math.sqrt(re[k] * re[k] + im[k] * im[k]) / wsum;
      ph[k] = math.atan2(im[k], re[k]);
    }
    return Spectrum(amp, ph, fs / n);
  }

  /// Decimated (max per bin group) spectrum for display.
  List<double> forDisplay(int maxPoints) {
    if (amp.length <= maxPoints) return amp.toList();
    final step = (amp.length / maxPoints).ceil();
    return [for (var i = 0; i < amp.length; i += step) amp.sublist(i, math.min(i + step, amp.length)).reduce(math.max)];
  }
}

double meanOf(List<double> x) => x.isEmpty ? double.nan : x.reduce((a, b) => a + b) / x.length;

double rmsOf(List<double> x) {
  if (x.isEmpty) return double.nan;
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return math.sqrt(s / x.length);
}

/// Harmonic analysis of a single channel.
class HarmonicAnalysis {
  final double f0;
  final double dc;
  final double rms;
  final List<double> amplitudes; // [1..n] peak amplitudes
  final List<double> phases; // [1..n] rad
  final double thd; // ratio (not %), relative to fundamental

  const HarmonicAnalysis({
    required this.f0,
    required this.dc,
    required this.rms,
    required this.amplitudes,
    required this.phases,
    required this.thd,
  });

  /// Fundamental is located as the spectrum maximum (above DC) and refined
  /// by parabolic interpolation of the windowed spectrum; harmonics are read
  /// at k*f0 bins (picks the max within +-1 bin).
  static HarmonicAnalysis of(Float64List x, double fs, {int harmonics = 10, WindowType window = WindowType.hann}) {
    final n = x.length;
    final sp = Spectrum.of(x, fs, window: window);
    final a = sp.amp;
    var kmax = 1;
    for (var k = 2; k < a.length; k++) {
      if (a[k] > a[kmax]) kmax = k;
    }
    var delta = 0.0;
    if (window == WindowType.hann && kmax > 0 && kmax < a.length - 1) {
      // interpolated DFT for Hann window (Grandke): exact for single tone
      final right = a[kmax + 1] > a[kmax - 1];
      final al = (right ? a[kmax + 1] : a[kmax - 1]) / a[kmax];
      delta = (2 * al - 1) / (al + 1) * (right ? 1 : -1);
    } else if (kmax > 0 && kmax < a.length - 1) {
      final y1 = math.log(a[kmax - 1] + 1e-300), y2 = math.log(a[kmax] + 1e-300), y3 = math.log(a[kmax + 1] + 1e-300);
      final d = y1 - 2 * y2 + y3;
      if (d != 0) delta = 0.5 * (y1 - y3) / d;
    }
    final f0 = (kmax + delta) * sp.df;
    final amps = <double>[];
    final phs = <double>[];
    for (var h = 1; h <= harmonics; h++) {
      final kc = (h * (kmax + delta)).round();
      if (kc >= a.length) {
        amps.add(double.nan);
        phs.add(double.nan);
        continue;
      }
      // window main lobe: sum energy of +-2 bins for amplitude estimate
      final w = window == WindowType.none ? 0 : 2;
      var e = 0.0;
      var best = kc;
      for (var k = math.max(1, kc - w); k <= math.min(a.length - 1, kc + w); k++) {
        e += a[k] * a[k];
        if (a[k] > a[best]) best = k;
      }
      final enbw = _enbw(window, n);
      amps.add(window == WindowType.none ? a[kc] : math.sqrt(e / enbw));
      phs.add(sp.phase[best]);
    }
    final fund = amps.isNotEmpty ? amps.first : double.nan;
    var hsum = 0.0;
    for (var i = 1; i < amps.length; i++) {
      if (amps[i].isFinite) hsum += amps[i] * amps[i];
    }
    return HarmonicAnalysis(
      f0: f0,
      dc: meanOf(x),
      rms: rmsOf(x),
      amplitudes: amps,
      phases: phs,
      thd: fund > 0 ? math.sqrt(hsum) / fund : double.nan,
    );
  }

  /// Equivalent noise bandwidth [bins] of the window (normalized to the
  /// coherent gain), used to convert main lobe energy to tone amplitude.
  static double _enbw(WindowType w, int n) {
    final c = w.coefficients(n);
    var s1 = 0.0, s2 = 0.0;
    for (final v in c) {
      s1 += v;
      s2 += v * v;
    }
    return n * s2 / (s1 * s1);
  }
}

/// Power quantities of a voltage/current pair (time domain integration).
class PowerAnalysis {
  final double urms, irms, p, s, q, pf;
  const PowerAnalysis(this.urms, this.irms, this.p, this.s, this.q, this.pf);

  static PowerAnalysis of(Float64List u, Float64List i) {
    final n = math.min(u.length, i.length);
    var su = 0.0, si = 0.0, sp = 0.0;
    for (var k = 0; k < n; k++) {
      su += u[k] * u[k];
      si += i[k] * i[k];
      sp += u[k] * i[k];
    }
    final ur = math.sqrt(su / n), ir = math.sqrt(si / n), p = sp / n;
    final s = ur * ir;
    final q = math.sqrt(math.max(0, s * s - p * p));
    return PowerAnalysis(ur, ir, p, s, q, s > 0 ? p / s : double.nan);
  }
}

/// Running statistics of a quantity over averaging cycles (TPQA
/// "On/Off Statistic": mean, std, type A uncertainty, % error).
class RunningStat {
  final int maxCount;
  final List<double> values = [];
  RunningStat([this.maxCount = 10]);

  void add(double v) {
    values.add(v);
    while (values.length > maxCount) {
      values.removeAt(0);
    }
  }

  void clear() => values.clear();

  double get last => values.isEmpty ? double.nan : values.last;
  double get average => meanOf(values);
  double get std {
    if (values.length < 2) return double.nan;
    final m = average;
    var s = 0.0;
    for (final v in values) {
      s += (v - m) * (v - m);
    }
    return math.sqrt(s / (values.length - 1));
  }

  double get uA => std / math.sqrt(values.length);

  /// Relative deviation of the last value from the mean [%].
  double get errorPercent => average == 0 ? double.nan : (last - average) / average * 100;
}
