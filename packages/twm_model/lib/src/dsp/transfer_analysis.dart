/// Transfer / interruption analysis (UPS transfer to bypass, sags, drop-outs)
/// from the samples of one record, with sub-period time resolution.
///
/// The steady waveform (fundamental + harmonics, least squares) is fitted
/// before and after the event. The event starts where the signal leaves the
/// "before" model and ends where it joins the "after" model (which may have
/// a different phase and amplitude); both edges are detected at 10 % of the
/// nominal peak and refined to the first/last sample above a small threshold
/// set from the fit residual (noise), so an interruption starting near a zero
/// crossing is not detected late. Edge uncertainty: half a sample period.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class TransferResult {
  final bool detected;

  /// Event start and duration [s] (start from the first sample of the record).
  final double start;
  final double duration;

  /// Largest deviation from the "before" waveform, relative to its peak.
  final double maxDeviation;

  /// Lowest relative amplitude during the event: 0 = interruption.
  final double depth;

  /// Phase of the fundamental after minus before the event [rad].
  final double phaseJump;

  /// Peak value of the fundamental before / after the event.
  final double peakBefore;
  final double peakAfter;
  final String message;

  const TransferResult({
    this.detected = false,
    this.start = double.nan,
    this.duration = double.nan,
    this.maxDeviation = double.nan,
    this.depth = double.nan,
    this.phaseJump = double.nan,
    this.peakBefore = double.nan,
    this.peakAfter = double.nan,
    this.message = '',
  });
}

/// Least squares model c0 + sum_h (a_h cos(h w t) + b_h sin(h w t)).
class _SineModel {
  final double w;
  final List<double> p; // c0, a1, b1, a2, b2, ...
  final double residualRms;
  _SineModel(this.w, this.p, this.residualRms);

  int get harmonics => (p.length - 1) ~/ 2;
  double value(double t) {
    // cos/sin of h w t by the Chebyshev recurrence from the fundamental
    // (two trigonometric calls per sample instead of two per harmonic)
    final c1 = math.cos(w * t), s1 = math.sin(w * t);
    var v = p[0] + p[1] * c1 + p[2] * s1;
    var cp = 1.0, sp = 0.0, c = c1, s = s1;
    for (var h = 2; h <= harmonics; h++) {
      final cn = 2 * c1 * c - cp, sn = 2 * c1 * s - sp;
      cp = c;
      sp = s;
      c = cn;
      s = sn;
      v += p[2 * h - 1] * c + p[2 * h] * s;
    }
    return v;
  }

  double get peak1 => math.sqrt(p[1] * p[1] + p[2] * p[2]);

  /// Phase of the fundamental (sine reference) at t = 0.
  double get phase1 => math.atan2(p[1], p[2]);

  static _SineModel? fit(Float64List x, double fs, double f, int from, int to, int harmonics) {
    final n = to - from;
    final m = 1 + 2 * harmonics;
    if (n < 2 * m) return null;
    final w = 2 * math.pi * f;
    final ata = List.generate(m, (_) => Float64List(m));
    final atb = Float64List(m);
    final row = Float64List(m);
    for (var i = from; i < to; i++) {
      final t = i / fs;
      final c1 = math.cos(w * t), s1 = math.sin(w * t);
      row[0] = 1;
      row[1] = c1;
      row[2] = s1;
      for (var h = 2; h <= harmonics; h++) {
        row[2 * h - 1] = 2 * c1 * row[2 * h - 3] - (h == 2 ? 1 : row[2 * h - 5]);
        row[2 * h] = 2 * c1 * row[2 * h - 2] - (h == 2 ? 0 : row[2 * h - 4]);
      }
      for (var a = 0; a < m; a++) {
        atb[a] += row[a] * x[i];
        final ra = row[a];
        final r = ata[a];
        for (var b = a; b < m; b++) {
          r[b] += ra * row[b];
        }
      }
    }
    for (var a = 0; a < m; a++) {
      for (var b = 0; b < a; b++) {
        ata[a][b] = ata[b][a];
      }
    }
    final p = _solve(ata, atb);
    if (p == null) return null;
    var r2 = 0.0;
    final model = _SineModel(w, p, 0);
    for (var i = from; i < to; i++) {
      final e = x[i] - model.value(i / fs);
      r2 += e * e;
    }
    return _SineModel(w, p, math.sqrt(r2 / n));
  }

  /// Gaussian elimination with partial pivoting.
  static List<double>? _solve(List<Float64List> a, Float64List b) {
    final n = b.length;
    final m = [
      for (var i = 0; i < n; i++) Float64List.fromList([...a[i], b[i]]),
    ];
    for (var c = 0; c < n; c++) {
      var piv = c;
      for (var r = c + 1; r < n; r++) {
        if (m[r][c].abs() > m[piv][c].abs()) piv = r;
      }
      if (m[piv][c].abs() < 1e-300) return null;
      final t = m[c];
      m[c] = m[piv];
      m[piv] = t;
      for (var r = c + 1; r < n; r++) {
        final k = m[r][c] / m[c][c];
        if (k == 0) continue;
        for (var j = c; j <= n; j++) {
          m[r][j] -= k * m[c][j];
        }
      }
    }
    final x = List<double>.filled(n, 0);
    for (var r = n - 1; r >= 0; r--) {
      var s = m[r][n];
      for (var j = r + 1; j < n; j++) {
        s -= m[r][j] * x[j];
      }
      x[r] = s / m[r][r];
    }
    return x;
  }
}

/// Frequency of the steady signal in [from, to) refined from [f0]: the phase
/// of the fundamental fitted on both halves must be the same at the right
/// frequency (phase difference method, a few iterations).
double _refineFrequency(Float64List x, double fs, double f0, int from, int to, int harmonics) {
  var f = f0;
  final mid = (from + to) ~/ 2;
  final dt = (to - from) / 2 / fs; // distance of the half centers [s]
  for (var it = 0; it < 4; it++) {
    final a = _SineModel.fit(x, fs, f, from, mid, harmonics), b = _SineModel.fit(x, fs, f, mid, to, harmonics);
    if (a == null || b == null) return f;
    var d = b.phase1 - a.phase1;
    d = math.atan2(math.sin(d), math.cos(d));
    final df = d / (2 * math.pi * dt);
    f += df;
    if (df.abs() < 1e-9 * f) break;
  }
  return f;
}

class TransferAnalysis {
  /// [x] samples of the voltage, [fs] sampling rate, [f0] fundamental
  /// frequency (e.g. from the harmonic analysis). [threshold] relative to
  /// the nominal peak; [harmonics] modelled in the steady waveform.
  static TransferResult analyze(Float64List x, double fs, double f0, {double threshold = 0.1, int harmonics = 10}) {
    final n = x.length;
    if (!(f0 > 0) || !f0.isFinite) return const TransferResult(message: 'no fundamental frequency');
    final period = fs / f0; // samples
    final h = math.max(1, math.min(harmonics, (fs / 2 / f0).floor() - 1));
    final refLen = (2 * period).ceil();
    if (n < 5 * period) return const TransferResult(message: 'record shorter than 5 periods');

    // 1: model from the first two periods (own frequency: a phase jump later in
    // the record biases the frequency of the whole record), then refined from
    // all samples before the event
    final fBefore = _refineFrequency(x, fs, f0, 0, refLen, h);
    var before = _SineModel.fit(x, fs, fBefore, 0, refLen, h);
    if (before == null || before.peak1 <= 0) return const TransferResult(message: 'no steady signal at the start');
    int firstOutside(_SineModel m, double thr, [int from = 0]) {
      for (var i = from; i < n; i++) {
        if ((x[i] - m.value(i / fs)).abs() > thr) return i;
      }
      return -1;
    }

    var a0 = before.peak1;
    var det = firstOutside(before, threshold * a0);
    if (det < 0) {
      return TransferResult(peakBefore: a0, peakAfter: a0, depth: 1, maxDeviation: 0, message: 'no event');
    }
    if (det >= refLen + period) {
      // refit on the steady part before the event (better frequency/phase
      // match): its last 100k samples, at least 4 periods (a longer fit costs
      // seconds at MSa/s and gains nothing at the event)
      final to = (det - period / 4).floor();
      final int from = math.max(0, to - math.max(100000, (4 * period).ceil()));
      final m = _SineModel.fit(x, fs, _refineFrequency(x, fs, fBefore, from, to, h), from, to, h);
      if (m != null) {
        before = m;
        a0 = m.peak1;
        det = firstOutside(before, threshold * a0, from);
      }
    }
    if (det < refLen) return const TransferResult(message: 'event within the first two periods');

    // 2: model after the event from the last two periods, end where the signal joins it
    // (the frequency may differ: UPS inverter before, grid after a transfer)
    final after = _SineModel.fit(x, fs, _refineFrequency(x, fs, f0, n - refLen, n, h), n - refLen, n, h);
    if (after == null) return const TransferResult(message: 'no steady signal at the end');
    var lastOut = -1;
    for (var i = n - 1; i >= det; i--) {
      if ((x[i] - after.value(i / fs)).abs() > threshold * a0) {
        lastOut = i;
        break;
      }
    }
    if (lastOut < 0 || lastOut >= n - refLen) {
      return TransferResult(
        detected: true,
        start: det / fs,
        peakBefore: a0,
        message: 'event lasts until the end of the record',
      );
    }

    // 3: refine both edges with a small threshold (noise of the fits)
    final fine = math.max(0.001 * a0, 6 * math.max(before.residualRms, after.residualRms));
    // the deviation can dip under the threshold for a sample or two when the
    // waveform crosses zero at an edge: take the first / last sample above it
    // within a quarter period outside the coarse detection
    final quarter = math.max(1, (period / 4).round());
    var s = det;
    for (var i = math.max(0, det - quarter); i < det; i++) {
      if ((x[i] - before.value(i / fs)).abs() > fine) {
        s = i;
        break;
      }
    }
    var e = lastOut;
    for (var i = math.min(n - 1, lastOut + quarter); i > lastOut; i--) {
      if ((x[i] - after.value(i / fs)).abs() > fine) {
        e = i;
        break;
      }
    }
    // edges midway between the last sample on the model and the first one off
    // it: a step (interruption) lies anywhere between them, +-0.5 sample
    final tStart = s - 0.5;
    final tEnd = e + 0.5;

    // 4: depth (half period moving RMS ratio) and largest deviation
    var maxDev = 0.0;
    for (var i = s; i <= e; i++) {
      maxDev = math.max(maxDev, (x[i] - before.value(i / fs)).abs());
    }
    var depth = 1.0;
    final win = math.max(1, (period / 2).round());
    if (e - s + 1 >= 1) {
      // lowest |x| envelope relative to the "before" model envelope over the event
      var lo = double.infinity;
      for (var i = s; i <= e; i += math.max(1, win ~/ 8)) {
        var sx = 0.0, sm = 0.0;
        final i1 = math.min(e + 1, i + win);
        if (i1 - i < win ~/ 4) continue;
        for (var k = i; k < i1; k++) {
          sx += x[k] * x[k];
          final v = before.value(k / fs);
          sm += v * v;
        }
        if (sm > 0) lo = math.min(lo, math.sqrt(sx / sm));
      }
      if (lo.isFinite) depth = lo;
    }
    var jump = after.phase1 - before.phase1;
    jump = math.atan2(math.sin(jump), math.cos(jump));
    return TransferResult(
      detected: true,
      start: tStart / fs,
      duration: (tEnd - tStart) / fs,
      maxDeviation: maxDev / a0,
      depth: depth,
      phaseJump: jump,
      peakBefore: a0,
      peakAfter: after.peak1,
    );
  }
}
