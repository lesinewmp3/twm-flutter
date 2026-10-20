@Tags(['octave'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

const home = '/home/e/papka_dlya_claude/twm_flutter';

/// Cross-validation of the Dart ports (browser version) against the
/// original TWM m-code in GNU Octave on identical recorded data.
void main() {
  late Directory tmp;
  late OctaveBridge oct;
  late QwtbService q;
  late String session;
  final store = IoFileStore();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('twm_port');
    oct = OctaveBridge(
      OctaveConfig(octprogPath: '$home/octave/octprog', packages: ['io', 'signal', 'statistics', 'optim']),
      apiRoot: '$home/octave',
    );
    q = QwtbService(oct);
    final dc = DigitizerConfig()..simulated.realtimeFactor = 0;
    dc.simulated.channels = [
      SimChannelConfig(
        name: 'u',
        range: 10,
        noiseRms: 1e-4,
        dc: 0.02,
        harmonics: [SimHarmonic(50.3, 7.0, 0.4), SimHarmonic(150.9, 0.21, 1.1), SimHarmonic(251.5, 0.07, -0.5)],
      ),
      SimChannelConfig(
        name: 'i',
        range: 1,
        noiseRms: 1e-5,
        harmonics: [SimHarmonic(50.3, 0.5, 0.1), SimHarmonic(150.9, 0.03, 0.2)],
      ),
    ];
    final corr = CorrectionsConfig(
      transducers: [
        TransducerConfig(path: '$home/data/corrections/transducers/dummy.vd/dummy.info', highChannel: 1),
        TransducerConfig(
          path: '$home/data/corrections/transducers/dummy.cs/dummy.info',
          type: TransducerType.shunt,
          highChannel: 2,
        ),
      ],
    );
    final mc = MeasurementConfig(fs: 10000, samplesCount: 20000, recordsCount: 2, folder: tmp.path, nameBase: 'x');
    session = await MeasurementEngine(
      store: store,
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: mc,
      corrections: corr,
    ).run();
  });
  tearDownAll(() async {
    await oct.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<Map<String, Map<String, List<double>>>> octave(String alg, [List<AlgorithmParameter> prm = const []]) async {
    await SessionWriter.writeQwtbSetup(store, p.dirname(session), ProcessingSetup(algorithmId: alg, parameters: prm));
    for (final r in [1, 2]) {
      await q.exec(session, record: r, group: 1, isLast: r == 2);
    }
    final d = await q.resultData(p.dirname(session), alg, ResultViewConfig(resultId: 2));
    return {
      for (final c in d.channels)
        if (c.isNotEmpty) c.first.tag: {for (final x in c) x.name: x.value},
    };
  }

  Future<Map<String, Map<String, List<double>>>> dart(String alg, [List<AlgorithmParameter> prm = const []]) async {
    final dp = DartProcessor(store);
    for (final r in [1, 2]) {
      await dp.process(
        session,
        ProcessingSetup(algorithmId: alg, parameters: prm),
        record: r,
      );
    }
    final d = await dp.resultData(session, alg, ResultViewConfig(resultId: 2));
    return {
      for (final c in d.channels)
        if (c.isNotEmpty) c.first.tag: {for (final x in c) x.name: x.value},
    };
  }

  void compare(
    Map<String, Map<String, List<double>>> o,
    Map<String, Map<String, List<double>>> d,
    Map<String, double> relTol,
  ) {
    final checks = <(String, double, double)>[];
    for (final tag in o.keys) {
      expect(d.containsKey(tag), isTrue, reason: 'channel $tag');
      for (final e in relTol.entries) {
        final key = e.key.split('#').first;
        final idx = e.key.contains('#') ? int.parse(e.key.split('#').last) : 0;
        final ov = o[tag]![key]![idx];
        final dv = d[tag]![key]![idx];
        final err = (dv - ov).abs() / (ov.abs() < 1e-9 ? 1 : ov.abs());
        print('$tag ${e.key}: octave $ov dart $dv rel.err ${err.toStringAsExponential(2)}');
        checks.add(('$tag ${e.key}', err, e.value));
      }
    }
    for (final c in checks) {
      expect(c.$2, lessThan(c.$3), reason: c.$1);
    }
  }

  test('TWM-WRMS', () async {
    compare(await octave('TWM-WRMS'), await dart('TWM-WRMS'), {'rms': 1e-6, 'dc': 1e-4});
  });

  test('TWM-PWRTDI', () async {
    compare(await octave('TWM-PWRTDI'), await dart('TWM-PWRTDI'), {
      'U': 1e-6,
      'I': 1e-6,
      'P': 1e-6,
      'S': 1e-6,
      'Q': 1e-5,
      'PF': 1e-6,
      'Udc': 1e-4,
    });
  });

  test('TWM-PSFE', () async {
    compare(await octave('TWM-PSFE'), await dart('TWM-PSFE'), {'f': 1e-9, 'A': 1e-7, 'phi': 1e-6});
  });

  test('TWM-WFFT', () async {
    final prm = [
      AlgorithmParameter('h_num', ['1:3']),
      AlgorithmParameter('window', ['flattop_144D']),
    ];
    compare(await octave('TWM-WFFT', prm), await dart('TWM-WFFT', prm), {
      'f#0': 1e-12,
      'A#0': 1e-9,
      'ph#0': 1e-9,
      'A#1': 1e-6,
      'ph#1': 1e-6,
      'rms': 1e-9,
      'dc': 1e-6,
    });
  });
}
