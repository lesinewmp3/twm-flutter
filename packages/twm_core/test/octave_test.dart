@Tags(['octave'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

final home = AppPaths.resolve().home;
final apiRoot = '$home/octave';

/// Integration with the real TWM processing module in GNU Octave.
void main() {
  late OctaveBridge oct;
  late QwtbService q;
  late Directory tmp;

  setUpAll(() async {
    oct = OctaveBridge(
      OctaveConfig(octprogPath: '$home/octave/octprog', packages: ['io', 'signal', 'statistics', 'optim']),
      apiRoot: apiRoot,
    );
    q = QwtbService(oct);
    tmp = Directory.systemTemp.createTempSync('twm_oct');
  });
  tearDownAll(() async {
    await oct.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('start and literals', () async {
    final info = await oct.start();
    expect(info['is_octave'], true);
    expect(info['has_qwtb'], true);
    final out = await oct.eval("disp(${OctaveBridge.toLiteral("it's\na test")})");
    expect(out, contains("it's"));
    expect(() => oct.eval('error("boom %d", 5)'), throwsA(isA<OctaveException>()));
    // engine still usable after error
    expect(await oct.eval('disp(1+1)'), contains('2'));
  });

  test('algorithms list and info', () async {
    final algs = await q.algorithms();
    expect(algs.map((a) => a.id), containsAll(['TWM-PSFE', 'TWM-PWRTDI', 'TWM-WFFT']));
    final pw = await q.algorithm('TWM-PWRTDI');
    expect(pw.hasUi, isTrue);
    expect(pw.parameters, isNotEmpty);
    expect(pw.outputs.map((o) => o.name), contains('P'));
  });

  test('measure with simulator, process TWM-PWRTDI, read results', () async {
    final dc = DigitizerConfig()..simulated.realtimeFactor = 0;
    // noise: the records differ, so their average differs from each of them
    for (final c in dc.simulated.channels) {
      c.noiseRms = 1e-4;
    }
    final mc = MeasurementConfig(
      fs: 10000,
      samplesCount: 20000,
      recordsCount: 2,
      folder: tmp.path,
      nameBase: 'pwr',
      processingEnabled: true,
      processing: ProcessingSetup(algorithmId: 'TWM-PWRTDI'),
    );
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
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: mc,
      corrections: corr,
      processor: (s, g, r, last) => q.exec(s, record: r, group: g, isLast: last),
    ).run();
    final root = p.dirname(session);
    final ri = await q.resultsInfo(root);
    expect(ri.exists, isTrue);
    expect(ri.lastAlgorithm, 'TWM-PWRTDI');
    expect(ri.files.length, 2);
    expect(ri.variables, contains('P'));
    final t = await q.results(root, 'TWM-PWRTDI', ResultViewConfig(resultId: 0));
    expect(t.rows.any((r) => r.first.startsWith('P')), isTrue);
    final d = await q.resultData(root, 'TWM-PWRTDI', ResultViewConfig(resultId: -1, variables: ['P', 'U', 'I']));
    final pq = d.channels.first.firstWhere((x) => x.name == 'P');
    // P = U1*I1*cos(phi) for harmonics present in both: only 50 Hz
    final expected = 7.0710678 * 0.5 / 2 * math.cos(0.2);
    expect(pq.value.first, closeTo(expected, 1e-3));
    // result 0 is the average of the records
    Future<double> pOf(int rid) async => (await q.resultData(
      root,
      'TWM-PWRTDI',
      ResultViewConfig(resultId: rid, variables: ['P']),
    )).channels.first.firstWhere((x) => x.name == 'P').value.first;
    final p1 = await pOf(1), p2 = await pOf(2);
    expect((p1 - p2).abs(), greaterThan(1e-9));
    final avg = await q.resultData(root, 'TWM-PWRTDI', ResultViewConfig(resultId: 0, variables: ['P']));
    expect(avg.resultId, 0);
    expect(avg.channels.first.firstWhere((x) => x.name == 'P').value.first, closeTo((p1 + p2) / 2, 1e-12));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('default setup (TWM-PSFE, one record): results table, octprog functions not shadowed', () async {
    // all alg_* folders on the path made unc2str of TWM-InpZ shadow the octprog one: the results
    // table failed with "sprintf: invalid format specified [unc2str:43]" - in a fresh engine only, a
    // qwtb() listing reorders the path
    await oct.restart();
    expect(await oct.eval("disp(which('unc2str'))"), contains(p.join('octprog', 'unc2str.m')));
    final dc = DigitizerConfig()..simulated.realtimeFactor = 0;
    final mc = MeasurementConfig(
      folder: tmp.path,
      nameBase: 'psfe',
      processingEnabled: true,
      processing: ProcessingSetup(algorithmId: 'TWM-PSFE'),
    );
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: mc,
      corrections: CorrectionsConfig(),
      processor: (s, g, r, last) => q.exec(s, record: r, group: g, isLast: last),
    ).run();
    final t = await q.results(p.dirname(session), 'TWM-PSFE', ResultViewConfig(resultId: -1));
    final f = t.rows.firstWhere((r) => r.first == 'f[u1]');
    expect(double.parse(f[1].replaceAll(' ', '')), closeTo(50, 1e-3));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
