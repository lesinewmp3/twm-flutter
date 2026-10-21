// Accuracy validation of the processing chain with signals of known value:
// simulated digitizer -> session on disk (TWM format) -> QWTB algorithms in
// GNU Octave (original TWM code), their Dart ports and the on-line analysis.
// Truth is computed analytically from the signal definition.
//
// The simulated digitizer is ideal (24 bit, 1 uV noise, no gain/phase
// errors), so this measures the error of the software alone. The accuracy of
// a real measurement is limited by the digitizer and transducers and their
// calibration - see the report text.
//
//   dart run tool/validate.dart [--report file.md] [case ...]
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

const home = '/home/e/papka_dlya_claude/twm_flutter';

class Tone {
  final double f; // [Hz]
  final double rms; // [V] or [A]
  final double ph; // [rad]
  const Tone(this.f, this.rms, [this.ph = 0]);
  double get amp => rms * math.sqrt2;
}

class Signal {
  final double dc;
  final List<Tone> tones;
  const Signal(this.tones, {this.dc = 0});

  double get rms => math.sqrt(dc * dc + tones.fold(0.0, (s, t) => s + t.rms * t.rms));

  /// THD of the harmonics 2..h of [f1] (fundamental referenced).
  double thd(double f1, int h) {
    final a1 = tones.firstWhere((t) => (t.f - f1).abs() < 1e-9).rms;
    var s = 0.0;
    for (final t in tones) {
      final k = t.f / f1;
      if ((k - k.round()).abs() < 1e-9 && k.round() >= 2 && k.round() <= h) s += t.rms * t.rms;
    }
    return math.sqrt(s) / a1;
  }

  Tone tone(double f) => tones.firstWhere((t) => (t.f - f).abs() < 1e-6);
}

class Case {
  final String name;
  final String what;
  final double fs;
  final int n;
  final double f1;
  final Signal u, i;
  final double divider; // Vin/Vout
  final double shunt; // V/A
  final List<double> rippleHarmonics; // h numbers of f1 checked by WFFT
  const Case(
    this.name,
    this.what, {
    required this.fs,
    required this.n,
    required this.f1,
    required this.u,
    required this.i,
    this.divider = 100,
    this.shunt = 0.05,
    this.rippleHarmonics = const [],
  });

  double get p {
    var s = u.dc * i.dc;
    for (final a in u.tones) {
      for (final b in i.tones) {
        if ((a.f - b.f).abs() < 1e-9) s += a.rms * b.rms * math.cos(a.ph - b.ph);
      }
    }
    return s;
  }

  double get s => u.rms * i.rms;
  double get pf => p / s;
}

const _phi99 = 0.14153947057149904; // acos(0.99)

final cases = <Case>[
  Case(
    'pfc-50Hz',
    'PFC input, nominal: 230 V / 10 A, 50 Hz, phi1 = 0.1 rad, THD(i) 2.8 %, THD(u) 1 %',
    fs: 10000,
    n: 10000,
    f1: 50,
    u: const Signal([Tone(50, 230), Tone(150, 1.84, 0.3), Tone(250, 1.38, -0.5)]),
    i: const Signal([
      Tone(50, 10, -0.1),
      Tone(150, 0.20, 0.8),
      Tone(250, 0.15, 1.9),
      Tone(350, 0.10, -2.1),
      Tone(450, 0.06, 0.4),
      Tone(550, 0.04, 1.2),
    ]),
  ),
  Case(
    'pfc-49.87Hz',
    'as pfc-50Hz at 49.87 Hz: non-integer number of periods in the record (real grid)',
    fs: 10000,
    n: 10000,
    f1: 49.87,
    u: const Signal([Tone(49.87, 230), Tone(149.61, 1.84, 0.3), Tone(249.35, 1.38, -0.5)]),
    i: const Signal([
      Tone(49.87, 10, -0.1),
      Tone(149.61, 0.20, 0.8),
      Tone(249.35, 0.15, 1.9),
      Tone(349.09, 0.10, -2.1),
      Tone(448.83, 0.06, 0.4),
      Tone(548.57, 0.04, 1.2),
    ]),
  ),
  Case(
    'in-110V-40Hz',
    'input range low end: 110 V, 40 Hz, PF 0.99',
    fs: 10000,
    n: 12345,
    f1: 40,
    shunt: 0.02,
    u: const Signal([Tone(40, 110)]),
    i: const Signal([Tone(40, 20, -_phi99), Tone(120, 0.4, 0.2)]),
  ),
  Case(
    'in-300V-60Hz',
    'input range high end: 300 V, 60 Hz, PF 0.99',
    fs: 10000,
    n: 12345,
    f1: 60,
    u: const Signal([Tone(60, 300)], dc: 0.5),
    i: const Signal([Tone(60, 7.5, -_phi99), Tone(180, 0.15, 0.2)]),
  ),
  Case(
    'pfc-50A-thd3',
    'current limit 50 A, THD(i) 2.99 % (close to the 3 % limit), PF ~0.99',
    fs: 20000,
    n: 20000,
    f1: 50,
    shunt: 0.01,
    u: const Signal([Tone(50, 230)]),
    i: const Signal([
      Tone(50, 50, -0.1),
      Tone(150, 1.20, 0.5),
      Tone(250, 0.75, 1.0),
      Tone(350, 0.45, 1.5),
      Tone(450, 0.175, 2.0),
    ]),
  ),
  Case(
    'pfc-ripple',
    'interleaved PFC ripple: 50 Hz 10 A + 120 kHz 0.05 A + 360 kHz 0.2 A, fs 2 MSa/s',
    fs: 2e6,
    n: 2000000,
    f1: 50,
    u: const Signal([Tone(50, 230), Tone(360000, 0.5, 0.7)]),
    i: const Signal([Tone(50, 10, -0.1), Tone(120000, 0.05, 0.3), Tone(360000, 0.2, 0.1)]),
    rippleHarmonics: [2400, 7200],
  ),
  Case(
    'inverter-20k',
    'inverter output: 230 V 50 Hz + 1 V residual at 20 kHz, THD(u) 0.6 %, fs 500 kSa/s',
    fs: 500000,
    n: 500000,
    f1: 50,
    u: const Signal([Tone(50, 230), Tone(150, 1.2, 0.2), Tone(250, 0.6, 0.9), Tone(20000, 1.0, 0.4)]),
    i: const Signal([Tone(50, 8, -0.05)]),
    rippleHarmonics: [400],
  ),
  Case(
    'fsbb-dc',
    'FSBB DC link: 380 V + 140 kHz 1.4 V ripple, 20 A + 140 kHz 0.7 A, fs 2 MSa/s',
    fs: 2e6,
    n: 1000000,
    f1: 140000,
    shunt: 0.01,
    u: const Signal([Tone(140000, 1.4, 0.0)], dc: 380),
    i: const Signal([Tone(140000, 0.7, -0.5)], dc: 20),
  ),
];

class Row {
  final String c, q;
  final double truth;
  final double? octave, dart, online;
  final bool absolute; // phase etc.
  Row(this.c, this.q, this.truth, {this.octave, this.dart, this.online, this.absolute = false});

  String get unit => q.startsWith('THD') ? 'pp' : 'rad';

  double? err(double? v) {
    if (v == null || !v.isFinite) return null;
    return absolute ? v - truth : (v - truth) / truth;
  }
}

String fmtErr(double? e, bool absolute, [String unit = 'rad']) {
  if (e == null) return '—';
  final s = e.abs().toStringAsExponential(1);
  return absolute ? '${e < 0 ? '-' : ''}$s $unit' : '${e < 0 ? '-' : ''}$s';
}

String fmtVal(double? v) {
  if (v == null || !v.isFinite) return '—';
  final a = v.abs();
  if (a >= 1000) return v.toStringAsFixed(4);
  if (a >= 1) return v.toStringAsPrecision(10);
  return v.toStringAsPrecision(8);
}

Future<void> main(List<String> args) async {
  String? reportPath;
  final only = <String>[];
  for (var k = 0; k < args.length; k++) {
    if (args[k] == '--report') {
      reportPath = args[++k];
    } else {
      only.add(args[k]);
    }
  }
  final tmp = Directory.systemTemp.createTempSync('twm_validate');
  final store = IoFileStore();
  final oct = OctaveBridge(
    OctaveConfig(octprogPath: '$home/octave/octprog', packages: ['io', 'signal', 'statistics', 'optim']),
    apiRoot: '$home/octave',
  );
  final q = QwtbService(oct);
  final rows = <Row>[];
  final times = <String, String>{};
  try {
    for (final c in cases) {
      if (only.isNotEmpty && !only.contains(c.name)) continue;
      stdout.writeln('== ${c.name}: ${c.what}');
      final sw = Stopwatch()..start();
      // transducers: copies of the dummy (flat) corrections with the case ratios
      final tdir = Directory(p.join(tmp.path, c.name, 'tr'))..createSync(recursive: true);
      String transducer(String src, String name, double ratio) {
        final dst = p.join(tdir.path, name);
        Process.runSync('cp', ['-r', '$home/data/corrections/transducers/$src', dst]);
        final f = File(p.join(dst, 'dummy.info'));
        f.writeAsStringSync(
          f.readAsStringSync().replaceFirst(RegExp(r'nominal ratio:: 1\.0'), 'nominal ratio:: $ratio'),
        );
        return f.path;
      }

      final corr = CorrectionsConfig(
        transducers: [
          TransducerConfig(
            path: transducer('dummy.vd', 'div.vd', c.divider),
            highChannel: 1,
            nominalRatio: c.divider,
          ),
          TransducerConfig(
            path: transducer('dummy.cs', 'shunt.cs', c.shunt),
            type: TransducerType.shunt,
            highChannel: 2,
            nominalRatio: c.shunt,
          ),
        ],
      );
      SimChannelConfig ch(String name, Signal s, double k, double range) => SimChannelConfig(
        name: name,
        range: range,
        dc: s.dc * k,
        harmonics: [for (final t in s.tones) SimHarmonic(t.f, t.amp * k, t.ph)],
      );
      final dc = DigitizerConfig()..type = DigitizerType.simulated;
      dc.simulated
        ..realtimeFactor = 0
        ..maxFs = 1e9
        ..bits = 24
        ..channels = [ch('u', c.u, 1 / c.divider, 10), ch('i', c.i, c.shunt, 1)];
      final mc = MeasurementConfig(
        fs: c.fs,
        samplesCount: c.n,
        recordsCount: 1,
        folder: p.join(tmp.path, c.name),
        nameBase: 's',
      );
      final session = await MeasurementEngine(
        store: store,
        digitizer: SimulatedDigitizer(dc),
        digitizerConfig: dc,
        config: mc,
        corrections: corr,
      ).run();
      final dir = p.dirname(session);

      Future<Map<String, Map<String, List<double>>>> octave(String alg, [List<AlgorithmParameter> prm = const []]) async {
        await SessionWriter.writeQwtbSetup(store, dir, ProcessingSetup(algorithmId: alg, parameters: prm));
        await q.exec(session, record: 1, group: 1, isLast: true);
        final d = await q.resultData(dir, alg, ResultViewConfig(resultId: -1, maxDim: ResultDim.vector, maxArray: 100));
        return {
          for (final ch in d.channels)
            if (ch.isNotEmpty) ch.first.tag: {for (final x in ch) x.name: x.value},
        };
      }

      Future<Map<String, Map<String, List<double>>>> dart(String alg, [List<AlgorithmParameter> prm = const []]) async {
        final dp = DartProcessor(store);
        await dp.process(session, ProcessingSetup(algorithmId: alg, parameters: prm), record: 1);
        final d = await dp.resultData(session, alg, ResultViewConfig(resultId: -1, maxDim: ResultDim.vector, maxArray: 100));
        return {
          for (final ch in d.channels)
            if (ch.isNotEmpty) ch.first.tag: {for (final x in ch) x.name: x.value},
        };
      }

      double? pick(Map<String, Map<String, List<double>>> r, String tag, String name, [int idx = 0]) {
        final v = r[tag]?[name];
        return v == null || v.length <= idx ? null : v[idx];
      }

      // on-line analysis of the recorded data (as the live view computes it)
      final rec = await (await SessionReader.open(store, session)).readRecord(1, 1);
      final online = OnlineAnalyzer(
        OnlineAnalysisConfig(harmonics: 40),
      ).analyze(rec.channels, 1 / rec.ts, corr.transducers);
      double? on(String name) {
        for (final x in online.quantities) {
          if (x.name == name) return x.value;
        }
        return null;
      }

      final wrmsO = await octave('TWM-WRMS');
      final wrmsD = await dart('TWM-WRMS');
      final pwrO = await octave('TWM-PWRTDI');
      final pwrD = await dart('TWM-PWRTDI');
      void add(String qn, double truth, {double? o, double? d, double? onl, bool abs = false}) =>
          rows.add(Row(c.name, qn, truth, octave: o, dart: d, online: onl, absolute: abs));

      add('U rms [V]', c.u.rms, o: pick(wrmsO, 'u1', 'rms'), d: pick(wrmsD, 'u1', 'rms'), onl: on('RMS u1'));
      add('I rms [A]', c.i.rms, o: pick(wrmsO, 'i1', 'rms'), d: pick(wrmsD, 'i1', 'rms'), onl: on('RMS i1'));
      if (c.u.dc != 0) add('U dc [V]', c.u.dc, o: pick(wrmsO, 'u1', 'dc'), d: pick(wrmsD, 'u1', 'dc'), onl: on('DC u1'));
      if (c.i.dc != 0) add('I dc [A]', c.i.dc, o: pick(wrmsO, 'i1', 'dc'), d: pick(wrmsD, 'i1', 'dc'), onl: on('DC i1'));
      add('P [W]', c.p, o: pick(pwrO, 'L1', 'P'), d: pick(pwrD, 'L1', 'P'), onl: on('P L1'));
      add('S [VA]', c.s, o: pick(pwrO, 'L1', 'S'), d: pick(pwrD, 'L1', 'S'), onl: on('S L1'));
      add('PF [-]', c.pf, o: pick(pwrO, 'L1', 'PF'), d: pick(pwrD, 'L1', 'PF'), onl: on('PF L1'));

      if (c.f1 < 1000) {
        final psfeO = await octave('TWM-PSFE');
        final psfeD = await dart('TWM-PSFE');
        add('f [Hz]', c.f1, o: pick(psfeO, 'u1', 'f'), d: pick(psfeD, 'u1', 'f'), onl: on('f u1'));
        // phase of i relative to u (absolute phases depend on the start time)
        double? dph(Map<String, Map<String, List<double>>> r) {
          final a = pick(r, 'u1', 'phi'), b = pick(r, 'i1', 'phi');
          if (a == null || b == null) return null;
          return math.atan2(math.sin(b - a), math.cos(b - a));
        }

        final onDph = () {
          final a = on('phi1 u1'), b = on('phi1 i1');
          if (a == null || b == null) return null;
          return math.atan2(math.sin(b - a), math.cos(b - a));
        }();
        final t1 = c.u.tone(c.f1), t2 = c.i.tone(c.f1);
        add('phi(i)-phi(u) [rad]', t2.ph - t1.ph, o: dph(psfeO), d: dph(psfeD), onl: onDph, abs: true);

        // THD to the 40th harmonic (IEC 61000-4-7 range)
        final thdO = await octave('TWM-THDWFFT', [
          AlgorithmParameter('H', ['40']),
        ]);
        double? thdPct(String tag) {
          final v = pick(thdO, tag, 'thd');
          return v; // [%]
        }

        // pure sine: absolute error [percentage points] = noise floor of the THD
        final tu = 100 * c.u.thd(c.f1, 40), ti = 100 * c.i.thd(c.f1, 40);
        add('THD(u) [%]', tu, o: thdPct('u1'), onl: on('THD u1'), abs: tu == 0);
        add('THD(i) [%]', ti, o: thdPct('i1'), onl: on('THD i1'), abs: ti == 0);

        if (c.rippleHarmonics.isNotEmpty) {
          final prm = [
            AlgorithmParameter('f_nom', ['${c.f1}']),
            AlgorithmParameter('h_num', ['[${c.rippleHarmonics.map((h) => h.toStringAsFixed(0)).join(' ')}]']),
          ];
          final wO = await octave('TWM-WFFT', prm);
          final wD = await dart('TWM-WFFT', prm);
          for (var k = 0; k < c.rippleHarmonics.length; k++) {
            final f = c.rippleHarmonics[k] * c.f1;
            for (final (tag, sig, unit) in [('u1', c.u, 'V'), ('i1', c.i, 'A')]) {
              final t = sig.tones.where((t) => (t.f - f).abs() < 1e-6);
              if (t.isEmpty) continue;
              add(
                '$tag ${(f / 1000).toStringAsFixed(0)} kHz amp [$unit]',
                t.first.amp,
                o: pick(wO, tag, 'A', k),
                d: pick(wD, tag, 'A', k),
              );
            }
          }
        }
      }
      times[c.name] = '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
      for (final r in rows.where((r) => r.c == c.name)) {
        stdout.writeln(
          '  ${r.q.padRight(24)} truth ${fmtVal(r.truth).padRight(14)} '
          'octave ${fmtErr(r.err(r.octave), r.absolute, r.unit).padRight(10)} '
          'dart ${fmtErr(r.err(r.dart), r.absolute, r.unit).padRight(10)} '
          'online ${fmtErr(r.err(r.online), r.absolute, r.unit)}',
        );
      }
    }
  } finally {
    await oct.dispose();
    tmp.deleteSync(recursive: true);
  }
  if (reportPath != null) {
    final sb = StringBuffer()
      ..writeln('| Case | Quantity | Truth | QWTB (Octave) err. | Dart port err. | On-line err. |')
      ..writeln('|---|---|---|---|---|---|');
    for (final r in rows) {
      sb.writeln(
        '| ${r.c} | ${r.q} | ${fmtVal(r.truth)} | ${fmtErr(r.err(r.octave), r.absolute, r.unit)} | '
        '${fmtErr(r.err(r.dart), r.absolute, r.unit)} | ${fmtErr(r.err(r.online), r.absolute, r.unit)} |',
      );
    }
    sb.writeln();
    for (final c in cases) {
      if (times.containsKey(c.name)) sb.writeln('- **${c.name}** (${times[c.name]}): ${c.what}');
    }
    File(reportPath).writeAsStringSync(sb.toString());
  }
  exit(0);
}
