@Tags(['octave'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

const twmRepo = '/home/e/papka_dlya_claude/src/TWM';
const apiRoot = '/home/e/papka_dlya_claude/twm_flutter/octave';

/// Integration with the real TWM processing module in GNU Octave.
void main() {
  late OctaveBridge oct;
  late QwtbService q;
  late Directory tmp;

  setUpAll(() async {
    oct = OctaveBridge(OctaveConfig(octprogPath: '$twmRepo/octprog', packages: ['io', 'signal', 'statistics', 'optim']),
        apiRoot: apiRoot);
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
    final mc = MeasurementConfig(
      fs: 10000, samplesCount: 20000, recordsCount: 2, folder: tmp.path, nameBase: 'pwr',
      processingEnabled: true,
      processing: ProcessingSetup(algorithmId: 'TWM-PWRTDI'),
    );
    final corr = CorrectionsConfig(transducers: [
      TransducerConfig(path: '$twmRepo/data/corrections/transducers/dummy.vd/dummy.info', highChannel: 1),
      TransducerConfig(
          path: '$twmRepo/data/corrections/transducers/dummy.cs/dummy.info',
          type: TransducerType.shunt, highChannel: 2),
    ]);
    final session = await MeasurementEngine(
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
  }, timeout: const Timeout(Duration(minutes: 5)));
}
