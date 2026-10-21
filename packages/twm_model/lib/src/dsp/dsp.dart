/// Signal processing for the live views and for the on-line analysis of
/// TPQA ("CVI Data Processing", originally NI Advanced Analysis Library).
/// Note: these results are indicative only - validated results come from
/// the QWTB algorithms (same statement as in the TPQA guide).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

export 'fft.dart';

enum WindowType {
  none('None (rectangular)'),
  hann('Hanning'),
  hamming('Hamming'),
  blackman('Blackman'),
  blackmanHarris('Blackman-Harris'),
  flatTop('Flat top');

  final String label;
  const WindowType(this.label);

  /// Cosine sum terms: w(x) = a0 - a1 cos(x) + a2 cos(2x) - ...
  List<double> get terms => switch (this) {
    WindowType.none => const [1.0],
    WindowType.hann => const [0.5, 0.5],
    WindowType.hamming => const [0.54, 0.46],
    WindowType.blackman => const [0.42, 0.5, 0.08],
    WindowType.blackmanHarris => const [0.35875, 0.48829, 0.14128, 0.01168],
    WindowType.flatTop => const [0.21557895, 0.41663158, 0.277263158, 0.083578947, 0.006947368],
  };

  static final _cache = <(WindowType, int), Float64List>{};

  /// Periodic window of length [n] (cached: the same length comes with every
  /// record; do not modify the returned list).
  Float64List coefficients(int n) {
    final key = (this, n);
    final c = _cache[key];
    if (c != null) return c;
    final a = terms;
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      final x = 2 * math.pi * i / n;
      var v = a[0];
      for (var k = 1; k < a.length; k++) {
        v += (k.isOdd ? -a[k] : a[k]) * math.cos(k * x);
      }
      w[i] = v;
    }
    if (_cache.length >= 6) _cache.remove(_cache.keys.first);
    _cache[key] = w;
    return w;
  }

  /// Equivalent noise bandwidth [bins]: n*sum(w^2)/sum(w)^2, exact for the
  /// periodic window when n > 2*terms.
  double get enbw {
    final a = terms;
    var s2 = a[0] * a[0];
    for (var k = 1; k < a.length; k++) {
      s2 += 0.5 * a[k] * a[k];
    }
    return s2 / (a[0] * a[0]);
  }
}

/// One sided amplitude spectrum (peak amplitudes), windowed and normalized
/// by the window coherent gain.
class Spectrum {
  final Float64List amp;
  final double df;
  final Float64List _re, _im;
  Float64List? _phase;

  Spectrum._(this.amp, this._re, this._im, this.df);

  static Spectrum of(Float64List x, double fs, {WindowType window = WindowType.none}) {
    final n = x.length;
    if (n < 2) return Spectrum._(Float64List(0), Float64List(0), Float64List(0), 0);
    final w = window.coefficients(n);
    var wsum = 0.0;
    final xr = Float64List(n);
    for (var i = 0; i < n; i++) {
      xr[i] = x[i] * w[i];
      wsum += w[i];
    }
    final (re, im) = Fft.real(xr);
    final h = re.length;
    final amp = Float64List(h);
    for (var k = 0; k < h; k++) {
      final s = (k == 0 || (n.isEven && k == n ~/ 2)) ? 1.0 : 2.0;
      amp[k] = s * math.sqrt(re[k] * re[k] + im[k] * im[k]) / wsum;
    }
    return Spectrum._(amp, re, im, fs / n);
  }

  /// Phase of every bin [rad] (computed on first use).
  Float64List get phase => _phase ??= Float64List.fromList([
    for (var k = 0; k < amp.length; k++) math.atan2(_im[k], _re[k]),
  ]);

  /// Phase of bin [k] [rad].
  double phaseAt(int k) => math.atan2(_im[k], _re[k]);

  /// Spectrum of the signal multiplied by [k] (transducer ratio).
  Spectrum scaled(double k) {
    if (k == 1) return this;
    final n = amp.length;
    final a = Float64List(n), re = Float64List(n), im = Float64List(n);
    for (var i = 0; i < n; i++) {
      a[i] = amp[i] * k.abs();
      re[i] = _re[i] * k;
      im[i] = _im[i] * k;
    }
    return Spectrum._(a, re, im, df);
  }

  /// Decimated (max per bin group) spectrum for display.
  List<double> forDisplay(int maxPoints) {
    if (amp.length <= maxPoints) return amp.toList();
    final step = (amp.length / maxPoints).ceil();
    final out = <double>[];
    for (var i = 0; i < amp.length; i += step) {
      var m = amp[i];
      final e = math.min(i + step, amp.length);
      for (var k = i + 1; k < e; k++) {
        if (amp[k] > m) m = amp[k];
      }
      out.add(m);
    }
    return out;
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

/// Weights for time domain averages (RMS, DC, power): Hann unless the
/// rectangular window is chosen. Averaging over a non-integer number of
/// periods with the rectangular window leaves an error ~ 1/(2 pi periods)
/// (0.3 % for 50 periods); the Hann window suppresses it to ~ 1/(8 pi periods^3).
Float64List? _timeWeights(WindowType w, int n) => w == WindowType.none || n < 8 ? null : WindowType.hann.coefficients(n);

double _wmean(Float64List x, Float64List? w) {
  if (x.isEmpty) return double.nan;
  if (w == null) return meanOf(x);
  var s = 0.0, sw = 0.0;
  for (var i = 0; i < x.length; i++) {
    s += w[i] * x[i];
    sw += w[i];
  }
  return s / sw;
}

double _wrms(Float64List x, Float64List? w) {
  if (x.isEmpty) return double.nan;
  if (w == null) return rmsOf(x);
  var s = 0.0, sw = 0.0;
  for (var i = 0; i < x.length; i++) {
    s += w[i] * x[i] * x[i];
    sw += w[i];
  }
  return math.sqrt(s / sw);
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
  /// by interpolation of the windowed spectrum; harmonics are read at k*f0
  /// bins (energy of the window main lobe). [spectrum] of [x] with [window]
  /// can be passed when it is already computed (live spectrum).
  static HarmonicAnalysis of(
    Float64List x,
    double fs, {
    int harmonics = 10,
    WindowType window = WindowType.hann,
    Spectrum? spectrum,
  }) {
    final n = x.length;
    final sp = spectrum ?? Spectrum.of(x, fs, window: window);
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
    // fewer than 2 periods of the fundamental: no meaningful frequency or
    // harmonics (a 1 ms record of 50 Hz gave "f = 508 Hz, THD = 223 %")
    final valid = kmax + delta >= 2;
    final f0 = valid ? (kmax + delta) * sp.df : double.nan;
    final enbw = window.enbw;
    final amps = <double>[];
    final phs = <double>[];
    for (var h = 1; h <= harmonics; h++) {
      final kc = (h * (kmax + delta)).round();
      if (!valid || kc >= a.length) {
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
      amps.add(window == WindowType.none ? a[kc] : math.sqrt(e / enbw));
      phs.add(sp.phaseAt(best));
    }
    final fund = amps.isNotEmpty ? amps.first : double.nan;
    var hsum = 0.0;
    for (var i = 1; i < amps.length; i++) {
      if (amps[i].isFinite) hsum += amps[i] * amps[i];
    }
    final tw = _timeWeights(window, n);
    return HarmonicAnalysis(
      f0: f0,
      dc: _wmean(x, tw),
      rms: _wrms(x, tw),
      amplitudes: amps,
      phases: phs,
      thd: fund > 0 ? math.sqrt(hsum) / fund : double.nan,
    );
  }
}

/// Power quantities of a voltage/current pair (time domain integration,
/// weighted by [window] - see [_timeWeights]).
class PowerAnalysis {
  final double urms, irms, p, s, q, pf;
  const PowerAnalysis(this.urms, this.irms, this.p, this.s, this.q, this.pf);

  static PowerAnalysis of(Float64List u, Float64List i, {WindowType window = WindowType.none}) {
    final n = math.min(u.length, i.length);
    final w = _timeWeights(window, n);
    var su = 0.0, si = 0.0, sp = 0.0, sw = 0.0;
    for (var k = 0; k < n; k++) {
      final wk = w == null ? 1.0 : w[k];
      su += wk * u[k] * u[k];
      si += wk * i[k] * i[k];
      sp += wk * u[k] * i[k];
      sw += wk;
    }
    final ur = math.sqrt(su / sw), ir = math.sqrt(si / sw), p = sp / sw;
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
