/// QWTB algorithms ported to Dart for the browser version (no GNU Octave).
/// Each port reproduces the estimator of the original TWM algorithm for
/// unity frequency corrections (transducer nominal ratio and ADC aperture
/// correction are applied); uncertainty evaluation is not available.
/// Validated against the original m-code in `test/qwtb_port_test.dart`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import 'qwtb_math.dart';

/// Result quantity of a Dart algorithm (same naming as QWTB outputs).
class DartQuantity {
  final String name;
  final List<double> value;
  final String text;
  const DartQuantity(this.name, this.value, {this.text = ''});
}

/// Input of an algorithm: one channel (`y`) or voltage/current pair.
class AlgInput {
  final double fs;
  final Float64List? y;
  final Float64List? u;
  final Float64List? i;
  final double aperture;
  final bool acCoupling;
  final Map<String, String> params;

  /// Relative time stamp of the first sample [s] (phase reference).
  final double timestamp;
  const AlgInput({
    required this.fs,
    this.y,
    this.u,
    this.i,
    this.timestamp = 0,
    this.aperture = 0,
    this.acCoupling = false,
    this.params = const {},
  });
}

abstract class DartAlgorithm {
  AlgorithmInfo get info;
  bool get isUi => info.hasUi;
  Map<String, DartQuantity> run(AlgInput a);

  static final List<DartAlgorithm> all = [TwmWrms(), TwmPwrtdi(), TwmWfft(), TwmPsfe()];

  static DartAlgorithm? byId(String id) {
    for (final a in all) {
      if (a.info.id == id) return a;
    }
    return null;
  }
}

AlgorithmInfo _info(
  String id,
  String name,
  String desc,
  List<(String, String)> outs, {
  bool ui = false,
  List<AlgorithmInput> params = const [],
}) => AlgorithmInfo(
  id: id,
  name: name,
  desc:
      '$desc\n\nBrowser version: Dart port of the TWM algorithm, frequency dependent corrections and '
      'uncertainty evaluation are not available (use the desktop version with GNU Octave).',
  license: 'MIT (port of TWM/QWTB algorithm)',
  inputs: params,
  outputs: [for (final o in outs) (name: o.$1, desc: o.$2)],
  hasUi: ui,
  supportDiff: true,
);

// ------------------------------------------------------------- PWRTDI ------

/// Shared core of TWM-PWRTDI / TWM-WRMS (`proc_wrms` and the PWRTDI wrapper).
class _PwrCore {
  late double fs;
  late Float64List uSpecA, iSpecA, f;
  late double udc, idc;
  late double uRms, iRms, p;
  late double qFft;

  void run(Float64List u0, Float64List i0, double fs, double aperture) {
    this.fs = fs;
    var n = u0.length;
    if (n.isOdd) n--;
    final u = Float64List.fromList(u0.sublist(0, n));
    final i = Float64List.fromList(i0.sublist(0, n));
    final fftSize = 1 << nextPow2(n / 4);
    final wf = flattop144dPeriodic(n);
    final su = ampPhSpectrum(u, fs, wf);
    final si = ampPhSpectrum(i, fs, wf);
    f = su.f;
    udc = su.amp[0];
    idc = si.amp[0];
    for (var k = 0; k < n; k++) {
      u[k] -= udc;
      i[k] -= idc;
    }
    final wGain = wf.reduce((a, b) => a + b) / n;
    final wRms = math.sqrt(wf.fold<double>(0, (s, v) => s + v * v) / n);
    // harmonic analysis for the sign of reactive power
    final uh = Float64List.fromList(su.amp), ih = Float64List.fromList(si.amp);
    final ph = Float64List(uh.length);
    for (var k = 0; k < ph.length; k++) {
      ph[k] = -(si.ph[k] - su.ph[k]); // U-I phase (ref channel 'i')
    }
    // aperture gain correction: identical for both channels
    var gain = <double>[1, 1];
    var fgr = <double>[0, fs / 2];
    if (aperture > 1e-12) {
      fgr = [for (final x in f) x];
      gain = [for (final x in f) (math.pi * aperture * (x + 1e-12)) / math.sin(math.pi * aperture * (x + 1e-12))];
      for (var k = 0; k < uh.length; k++) {
        uh[k] *= gain[k];
        ih[k] *= gain[k];
      }
    }
    qFft = _qSign(uh, ih, ph);
    final uf = tdFftFilter(u, fs, fftSize, fgr, gain, List.filled(gain.length, 0));
    final ifl = tdFftFilter(i, fs, fftSize, fgr, gain, List.filled(gain.length, 0));
    final m = uf.length;
    final w = blackmanHarrisPeriodic(m);
    var w2 = 0.0, su2 = 0.0, si2 = 0.0, sp = 0.0;
    for (var k = 0; k < m; k++) {
      final ww = w[k] * w[k];
      w2 += ww;
      su2 += ww * uf[k] * uf[k];
      si2 += ww * ifl[k] * ifl[k];
      sp += ww * uf[k] * ifl[k];
    }
    final W = math.pow(w2 / m, -0.5).toDouble();
    uRms = W * math.sqrt(su2 / m);
    iRms = W * math.sqrt(si2 / m);
    p = W * W * sp / m;
    // DC gain (aperture correction at DC = 1)
    final s1 = ampPhSpectrum(uf, fs, flattop144dPeriodic(m));
    final s2 = ampPhSpectrum(ifl, fs, flattop144dPeriodic(m));
    uSpecA = s1.amp;
    iSpecA = s2.amp;
    f = s1.f;
    // window gains kept for reference (noise estimation not needed)
    assert(wGain > 0 && wRms > 0);
  }

  /// Sum of harmonic reactive powers (TWM harmonic search, up to 10
  /// largest harmonics) - only its sign is used.
  double _qSign(Float64List uh, Float64List ih, Float64List ph) {
    const wSize = 9;
    final n = uh.length;
    final hRatio = math.max(10e-6, math.pow(10, -144 / 20).toDouble());
    var msk = [for (var k = wSize - 1; k <= n - 4; k++) k];
    var uMax = -1.0, iMax = -1.0;
    var isU = true;
    const refIsU = true;
    final hList = <int>[];
    for (var h = 0; h < 100 && msk.isNotEmpty; h++) {
      var best = msk.first;
      for (final k in msk) {
        if ((isU ? uh[k] : ih[k]) > (isU ? uh[best] : ih[best])) best = k;
      }
      if (uMax >= 0 && uh[best] < uMax * hRatio && ih[best] < iMax * hRatio) {
        if (refIsU == isU) {
          isU = !isU;
        } else {
          break;
        }
      }
      uMax = math.max(uMax, uh[best]);
      iMax = math.max(iMax, ih[best]);
      hList.add(best);
      msk = msk.where((k) => k < best - wSize || k > best + wSize).toList();
    }
    var q = 0.0;
    for (var h = 0; h < math.min(hList.length, 10); h++) {
      final k = hList[h];
      q += 0.5 * uh[k] * ih[k] * math.sin(ph[k]);
    }
    return q;
  }
}

class TwmPwrtdi extends DartAlgorithm {
  @override
  final AlgorithmInfo info = _info(
    'TWM-PWRTDI',
    'Power by Time Domain Integration',
    'Four quadrant power meter by time-domain integration method for non-coherent sampling.',
    [
      ('U', 'RMS voltage'),
      ('I', 'RMS current'),
      ('P', 'Active power'),
      ('S', 'Apparent power'),
      ('Q', 'Reactive power'),
      ('PF', 'Power factor'),
      ('quadrant', 'Quadrant number'),
      ('phi_ef', 'Effective phase shift acos(PF) [rad]'),
      ('Udc', 'DC voltage component'),
      ('Idc', 'DC current component'),
      ('Pdc', 'DC power component'),
      ('spec_f', 'Spectrum frequency'),
      ('spec_U', 'Spectrum voltage channel'),
      ('spec_I', 'Spectrum current channel'),
      ('spec_S', 'Spectrum apparent power'),
    ],
    ui: true,
  );

  @override
  Map<String, DartQuantity> run(AlgInput a) {
    final c = _PwrCore()..run(a.u!, a.i!, a.fs, a.aperture);
    var u = c.uRms, i = c.iRms, p = c.p;
    var q = math.sqrt((u * i * u * i - p * p).abs()) * (c.qFft < 0 ? -1 : 1);
    final p0 = c.udc * c.idc;
    if (!a.acCoupling) {
      u = math.sqrt(u * u + c.udc * c.udc);
      i = math.sqrt(i * i + c.idc * c.idc);
      p = p + p0;
    }
    final s = u * i;
    final quad = p >= 0 && q >= 0
        ? 'Q1'
        : p < 0 && q >= 0
        ? 'Q2'
        : p < 0 && q < 0
        ? 'Q3'
        : 'Q4';
    final spS = [for (var k = 0; k < c.uSpecA.length; k++) c.uSpecA[k] * c.iSpecA[k]];
    return {
      'U': DartQuantity('U', [u]),
      'I': DartQuantity('I', [i]),
      'P': DartQuantity('P', [p]),
      'S': DartQuantity('S', [s]),
      'Q': DartQuantity('Q', [q]),
      'PF': DartQuantity('PF', [p / s]),
      'quadrant': DartQuantity('quadrant', const [], text: quad),
      'phi_ef': DartQuantity('phi_ef', [math.atan2(q, p)]),
      'Udc': DartQuantity('Udc', [c.udc]),
      'Idc': DartQuantity('Idc', [c.idc]),
      'Pdc': DartQuantity('Pdc', [p0]),
      'spec_f': DartQuantity('spec_f', c.f),
      'spec_U': DartQuantity('spec_U', c.uSpecA),
      'spec_I': DartQuantity('spec_I', c.iSpecA),
      'spec_S': DartQuantity('spec_S', spS),
    };
  }
}

/// TWM-WRMS = PWRTDI with the same signal in both channels.
class TwmWrms extends DartAlgorithm {
  @override
  final AlgorithmInfo info = _info(
    'TWM-WRMS',
    'RMS value by Windowed Time Domain Integration',
    'RMS level calculation by time-domain integration method for non-coherent sampling.',
    [('rms', 'RMS value'), ('dc', 'DC component'), ('spec_f', 'Spectrum frequency'), ('spec_A', 'Spectrum amplitude')],
  );

  @override
  Map<String, DartQuantity> run(AlgInput a) {
    final r = TwmPwrtdi().run(AlgInput(fs: a.fs, u: a.y, i: a.y, aperture: a.aperture, acCoupling: a.acCoupling));
    return {
      'rms': DartQuantity('rms', r['U']!.value),
      'dc': DartQuantity('dc', r['Udc']!.value),
      'spec_f': DartQuantity('spec_f', r['spec_f']!.value),
      'spec_A': DartQuantity('spec_A', r['spec_U']!.value),
    };
  }
}

// --------------------------------------------------------------- WFFT ------

/// Periodic window coefficients as QWTB `window_coeff(win, N, 'periodic')`.
Float64List? qwtbWindow(String win, int n) {
  List<double>? c;
  switch (win) {
    case 'rect':
      return null;
    case 'hanning':
      c = [0.5, -0.5];
    case 'hamming':
      c = [0.54, -0.46];
    case 'blackman':
      c = [0.42, -0.5, 0.08];
    case 'blackmanharris':
      c = [0.35875, -0.48829, 0.14128, -0.01168];
    case 'flattop_matlab':
      c = [0.21557895, -0.41663158, 0.277263158, -0.083578947, 0.006947368];
    case 'flattop_144D':
      return flattop144dPeriodic(n);
    default:
      throw ArgumentError('Window "$win" is not available in the browser version (${TwmWfft.windows.join(', ')}).');
  }
  final w = Float64List(n);
  for (var k = 0; k < n; k++) {
    var v = 0.0;
    for (var j = 0; j < c.length; j++) {
      v += c[j] * math.cos(2 * math.pi * j * k / n);
    }
    w[k] = v;
  }
  return w;
}

/// Parses Matlab style vector/range: "1:5", "1:2:9", "1 3 5", "1;3".
List<double> parseMatlabVector(String s) {
  final out = <double>[];
  for (final part in s.replaceAll(RegExp(r'[\[\]]'), '').split(RegExp(r'[;,\s]+')).where((t) => t.isNotEmpty)) {
    final r = part.split(':').map(double.parse).toList();
    if (r.length == 1) {
      out.add(r[0]);
    } else {
      final step = r.length == 3 ? r[1] : 1.0;
      final end = r.length == 3 ? r[2] : r[1];
      for (var v = r[0]; step > 0 ? v <= end + 1e-12 : v >= end - 1e-12; v += step) {
        out.add(v);
      }
    }
  }
  return out;
}

/// Literal port of TWM-WFFT (`wfft_core.m` without corrections/uncertainty).
class TwmWfft extends DartAlgorithm {
  static const windows = ['rect', 'flattop_144D', 'flattop_matlab', 'blackmanharris', 'blackman', 'hanning', 'hamming'];

  @override
  final AlgorithmInfo info = _info(
    'TWM-WFFT',
    'Windowed FFT spectrum analysis',
    'Windowed FFT for single or multiharmonic estimation. If "f_nom" is not given, the frequency is found by PSFE; '
        '"h_num" selects relative harmonics (e.g. 1:10).',
    [
      ('A', 'Amplitude(s)'),
      ('ph', 'Phase angle(s)'),
      ('rms', 'RMS level'),
      ('dc', 'DC offset'),
      ('f', 'Selected DFT bin frequencies'),
      ('A_rel0', 'Amplitude ratios to fundamental [%]'),
      ('ph_rel0', 'Phase difference from fundamental'),
      ('spec_f', 'Full spectrum frequency'),
      ('spec_A', 'Full spectrum amplitudes'),
    ],
    params: const [
      AlgorithmInput(name: 'f_nom', desc: 'Nominal frequency [Hz]', optional: true, parameter: true),
      AlgorithmInput(
        name: 'h_num',
        desc: 'Relative harmonic frequencies list or Matlab style range expression (e.g. 1:2:7)',
        optional: true,
        parameter: true,
      ),
      AlgorithmInput(
        name: 'window',
        desc: 'Name of window function',
        optional: true,
        parameter: true,
        enumValues: windows,
      ),
    ],
  );

  @override
  Map<String, DartQuantity> run(AlgInput a) {
    final y = a.y!;
    final n = y.length;
    var fNom = parseMatlabVector(a.params['f_nom'] ?? '');
    if (fNom.isEmpty) fNom = [psfe(y, 1 / a.fs).f];
    final hNum = a.params['h_num'] ?? '';
    if (hNum.trim().isNotEmpty) {
      if (fNom.length > 1) throw ArgumentError("TWM-WFFT: vector 'f_nom' not allowed with 'h_num'");
      fNom = [for (final h in parseMatlabVector(hNum)) fNom.first * h];
    }
    if (fNom.any((f) => f >= 0.5 * a.fs)) {
      throw ArgumentError('Some of requested harmonic components are outside Nyquist limit!');
    }
    final win = (a.params['window'] ?? '').trim().isEmpty ? 'rect' : a.params['window']!.trim();
    final s = ampPhSpectrum(y, a.fs, qwtbWindow(win, n));
    final fh = s.f;
    final m = fh.length;
    final A = Float64List.fromList(s.amp);
    final ph = Float64List(m);
    for (var k = 0; k < m; k++) {
      ph[k] = s.ph[k] - fh[k] * a.timestamp * 2 * math.pi;
    }
    ph[0] = 0;
    if (a.aperture > 1e-12) {
      for (var k = 0; k < m; k++) {
        final x = math.pi * a.aperture * (fh[k] + 1e-12);
        A[k] *= x / math.sin(x);
        ph[k] += math.pi * a.aperture * fh[k];
      }
    }
    for (var k = 0; k < m; k++) {
      ph[k] = (ph[k] + math.pi) % (2 * math.pi) - math.pi;
    }
    ph[0] = 0;
    // harmonic search for the rms value
    final aMax = A.reduce(math.max);
    const wSize = 11;
    final ax = Float64List(m);
    for (var k = wSize - 1; k < m; k++) {
      ax[k] = A[k];
    }
    final hList = <int>[];
    for (var h = 0; h < 100; h++) {
      var id = 0;
      for (var k = 1; k < m; k++) {
        if (ax[k] > ax[id]) id = k;
      }
      if (ax[id] < aMax * 10e-6) break;
      hList.add(id);
      for (var k = math.max(id - wSize, 0); k <= math.min(id + wSize, m - 1); k++) {
        ax[k] = 0;
      }
    }
    final rms = math.sqrt(A[0] * A[0] + hList.fold<double>(0, (t, k) => t + 0.5 * A[k] * A[k]));
    final fid = [for (final f in fNom) (f / fh[1]).round().clamp(0, m - 1)];
    final fo = [for (final k in fid) fh[k]];
    final ao = [for (final k in fid) A[k]];
    final po = [for (final k in fid) ph[k]];
    return {
      'A': DartQuantity('A', ao),
      'ph': DartQuantity('ph', po),
      'rms': DartQuantity('rms', [rms]),
      'dc': DartQuantity('dc', [A[0]]),
      'f': DartQuantity('f', fo),
      'A_rel0': DartQuantity('A_rel0', [for (final v in ao) 100 * v / ao.first]),
      'ph_rel0': DartQuantity('ph_rel0', [
        for (var k = 0; k < po.length; k++) (po[k] - po.first * fo[k] / fo.first + math.pi) % (2 * math.pi) - math.pi,
      ]),
      'spec_f': DartQuantity('spec_f', fh),
      'spec_A': DartQuantity('spec_A', A),
    };
  }
}

// --------------------------------------------------------------- PSFE ------

/// TWM-PSFE: Phase Sensitive Frequency Estimator (Lapuh) - frequency,
/// amplitude and phase of the dominant component.
class TwmPsfe extends DartAlgorithm {
  @override
  final AlgorithmInfo info = _info(
    'TWM-PSFE',
    'Phase Sensitive Frequency Estimator',
    'Calculation of fundamental harmonic parameters by Phase Sensitive Frequency Estimator for non-coherent '
        'sampling (frequency, amplitude and phase).',
    [
      ('f', 'Frequency of main signal component'),
      ('A', 'Amplitude of main signal component'),
      ('phi', 'Phase of main signal component'),
    ],
    params: const [
      AlgorithmInput(
        name: 'comp_timestamp',
        desc: 'Enable compensation of phase by timestamp (default off)',
        optional: true,
        parameter: true,
        enumValues: ['on', 'off'],
      ),
    ],
  );

  @override
  Map<String, DartQuantity> run(AlgInput a) {
    final r = psfe(a.y!, 1 / a.fs);
    var amp = r.a, ph = r.ph;
    // TWM-PSFE wrapper: optional time stamp compensation, aperture correction
    final comp = (a.params['comp_timestamp'] ?? '').trim().toLowerCase();
    if (comp == 'on' || comp == '1') ph -= a.timestamp * r.f * 2 * math.pi;
    if (a.aperture > 1e-12) {
      final x = math.pi * a.aperture * r.f;
      amp *= x / math.sin(x);
      ph += x;
    }
    ph = (ph + math.pi) % (2 * math.pi) - math.pi;
    return {
      'f': DartQuantity('f', [r.f]),
      'A': DartQuantity('A', [amp]),
      'phi': DartQuantity('phi', [ph]),
    };
  }
}

/// Literal port of QWTB `PSFE.m` (Rado Lapuh, 2016).
({double f, double a, double ph}) psfe(Float64List record, double ts) {
  const twopi = 2 * math.pi;
  final m = record.length;
  final m2 = m / 2;
  const costError = 2.4e-12;
  const maxIter = 20;
  final mean = record.reduce((p, q) => p + q) / m;
  final rec = Float64List.fromList([for (final v in record) v - mean]);
  // initial guess from FFT peak (zero padded to 2^n)
  final nfft = 1 << nextPow2(m);
  final xr = Float64List(nfft)..setAll(0, rec);
  final xi = Float64List(nfft);
  Fft.radix2(xr, xi);
  var imax = 0;
  var vmax = -1.0;
  for (var k = 0; k < nfft ~/ 2; k++) {
    final v = xr[k] * xr[k] + xi[k] * xi[k];
    if (v > vmax) {
      vmax = v;
      imax = k;
    }
  }
  var fa = imax / (ts * nfft);
  if (fa == 0) return (f: 0, a: 0, ph: 0);
  var iter = 0;
  while (true) {
    iter++;
    final dmax = m2.truncate();
    final faTs = fa * ts;
    int d0;
    if (dmax < (1 / faTs).truncate()) {
      d0 = dmax;
    } else {
      // candidates: round(floor(dmax*faTs)/faTs) : -1/faTs : dmax/2, rounded
      final start = (((dmax * faTs).floor()) / faTs).round().toDouble();
      final dc = <int>[];
      for (var v = start; v >= dmax / 2 - 1e-9; v -= 1 / faTs) {
        dc.add(v.round());
      }
      if (dc.isEmpty) {
        d0 = dmax;
      } else {
        var best = 0;
        var bestErr = double.infinity;
        for (var k = 0; k < dc.length; k++) {
          final dd = dc[k] * faTs;
          final e = (dd.round() / dd - 1).abs();
          if (e < bestErr) {
            bestErr = e;
            best = k;
          }
        }
        d0 = dc[best];
      }
    }
    final w0 = m - d0;
    final fTs = twopi * faTs;
    final x1 = _fit(rec, 0, w0, fTs);
    var ph1 = math.atan(-x1[1] / x1[0]);
    if (x1[0] >= 0) ph1 += math.pi;
    final x2 = _fit(rec, d0, w0, fTs);
    var ph2 = math.atan(-x2[1] / x2[0]);
    if (x2[0] >= 0) ph2 += math.pi;
    final c1 = twopi * ts * d0;
    final dphA = c1 * fa;
    final dphC0 = ph2 - ph1;
    final p = ((dphA - dphC0) / twopi).round();
    final dphC = dphC0 + twopi * p;
    final eps = (dphA - dphC).abs() / c1 / fa / m;
    fa = fa - (dphA - dphC) / c1;
    if (eps == 0 || eps < costError || iter >= maxIter) {
      final a = (math.sqrt(x1[0] * x1[0] + x1[1] * x1[1]) + math.sqrt(x2[0] * x2[0] + x2[1] * x2[1])) / 2;
      return (f: fa, a: a, ph: ph1 - math.pi / 2);
    }
  }
}

/// Least squares [cos, sin, 1] model of record[off .. off+w0-1].
List<double> _fit(Float64List rec, int off, int w0, double fTs) {
  var cc = 0.0, cs = 0.0, c1 = 0.0, ss = 0.0, s1 = 0.0, n1 = 0.0, yc = 0.0, ys = 0.0, y1 = 0.0;
  for (var k = 0; k < w0; k++) {
    final c = math.cos(fTs * k), s = math.sin(fTs * k), y = rec[off + k];
    cc += c * c;
    cs += c * s;
    c1 += c;
    ss += s * s;
    s1 += s;
    n1 += 1;
    yc += c * y;
    ys += s * y;
    y1 += y;
  }
  return _solve3(
    [
      [cc, cs, c1],
      [cs, ss, s1],
      [c1, s1, n1],
    ],
    [yc, ys, y1],
  );
}

List<double> _solve3(List<List<double>> a, List<double> b) {
  final m = [
    for (var i = 0; i < 3; i++) [...a[i], b[i]],
  ];
  for (var c = 0; c < 3; c++) {
    var p = c;
    for (var r = c + 1; r < 3; r++) {
      if (m[r][c].abs() > m[p][c].abs()) p = r;
    }
    final t = m[c];
    m[c] = m[p];
    m[p] = t;
    for (var r = 0; r < 3; r++) {
      if (r == c) continue;
      final k = m[r][c] / m[c][c];
      for (var j = c; j < 4; j++) {
        m[r][j] -= k * m[c][j];
      }
    }
  }
  return [for (var i = 0; i < 3; i++) m[i][3] / m[i][i]];
}
