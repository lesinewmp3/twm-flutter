@Tags(['octave'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

void main() {
  late Directory tmp;
  late LocalBackend b;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('twm_be');
    b = LocalBackend(
      AppPaths.resolve(home: '/home/e/papka_dlya_claude/twm_flutter', settingsFile: p.join(tmp.path, 's.json')),
    );
  });
  tearDown(() async {
    await b.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('settings defaults and persistence', () async {
    final s = await b.loadSettings();
    expect(Directory(s.octave.octprogPath).existsSync(), isTrue);
    s.measurement.fs = 12345;
    await b.saveSettings(s);
    expect((await b.loadSettings()).measurement.fs, 12345);
  });

  test('measurement with on-line analysis and QWTB processing', () async {
    final s = await b.loadSettings();
    s.digitizer.simulated.realtimeFactor = 0;
    s.measurement
      ..folder = tmp.path
      ..nameBase = 'm'
      ..fs = 10000
      ..samplesCount = 10000
      ..recordsCount = 2
      ..processingEnabled = true
      ..processing = ProcessingSetup(algorithmId: 'TWM-PSFE');
    final dummy = p.join(b.paths.corrections, 'transducers');
    s.corrections.transducers = [
      TransducerConfig(path: p.join(dummy, 'dummy.vd', 'dummy.info'), highChannel: 1),
      TransducerConfig(path: p.join(dummy, 'dummy.cs', 'dummy.info'), type: TransducerType.shunt, highChannel: 2),
    ];
    final events = <BackendEvent>[];
    final sub = b.events.listen(events.add);
    await b.startMeasurement(s);
    final fin = await b.events.firstWhere((e) => e is FinishedEvent) as FinishedEvent;
    await sub.cancel();
    expect(fin.error, isEmpty);
    final wf = events.whereType<WaveformEvent>().first;
    expect(wf.spectra.length, 2);
    final onl = OnlineResult.fromJson(wf.online!);
    final p1 = onl.quantities.firstWhere((q) => q.name == 'P L1');
    expect(p1.value, closeTo(7.0710678 * 0.5 / 2 * 0.9800665778, 2e-3));
    expect(events.whereType<ProcessingEvent>().where((e) => !e.busy && e.error.isEmpty).length, 2);

    final sum = await b.sessionSummary(fin.sessionPath);
    expect(sum.recordsPerGroup, [2]);
    expect(sum.transducerTags, ['u1', 'i1']);
    final ri = await b.resultsInfo(fin.sessionPath);
    expect(ri.algorithms, ['TWM-PSFE']);
    final t = await b.results(fin.sessionPath, 'TWM-PSFE', ResultViewConfig(resultId: 0));
    expect(t.rows, isNotEmpty);
    final wd = await b.readRecord(fin.sessionPath, 1, 1, maxPoints: 1000);
    expect(wd.channels.first.length, 1000);
  });
}
