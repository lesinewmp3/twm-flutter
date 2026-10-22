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
    b = LocalBackend(AppPaths.resolve(settingsFile: p.join(tmp.path, 's.json')));
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
    s.online
      ..saveResults = true
      ..resultsFile = p.join(tmp.path, 'online', 'cvi.csv');
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

    final csv = File(s.online.resultsFile).readAsLinesSync();
    expect(csv.length, 3); // header + 2 records
    expect(csv.first, contains('P L1 [W]'));
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

  Future<AppSettings> continuousSetup({
    required ExecutionMode execution,
    bool atOnce = false,
    String alg = 'TWM-PSFE',
  }) async {
    final s = await b.loadSettings();
    s.digitizer.simulated.realtimeFactor = 1;
    s.measurement
      ..folder = tmp.path
      ..nameBase = 'c'
      ..fs = 10000
      ..samplesCount = 5000
      ..continuous = true
      ..saveRecords = true
      ..processingEnabled = true
      ..processing = ProcessingSetup(algorithmId: alg, execution: execution, wholeAverageAtOnce: atOnce);
    s.online.monitorWindowMs = 80;
    return s;
  }

  Future<void> processingIdle(List<BackendEvent> events) async {
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(end)) {
      final p = events.whereType<ProcessingEvent>();
      final queued = events.whereType<StatusEvent>().where((e) => e.message.contains('queued')).length;
      if (p.isNotEmpty && !p.last.busy && (queued == 0 || events.last is StatusEvent)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!events.whereType<ProcessingEvent>().last.busy) return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('processing did not finish');
  }

  test('continuous measurement with parallel record processing: no gaps between records', () async {
    final s = await continuousSetup(execution: ExecutionMode.parallelRecords);
    final events = <BackendEvent>[];
    final liveAt = <int>[];
    final sw = Stopwatch()..start();
    final sub = b.events.listen((e) {
      events.add(e);
      if (e is LiveEvent) liveAt.add(sw.elapsedMilliseconds);
    });
    await b.startMeasurement(s);
    await Future<void>.delayed(const Duration(seconds: 6));
    await b.stopMeasurement();
    await b.events.firstWhere((e) => e is FinishedEvent);
    final stored = events.whereType<RecordStoredEvent>().length;
    // 0.5 s records over 6 s: the acquisition does not wait for GNU Octave
    expect(stored, greaterThanOrEqualTo(10));
    final gaps = [for (var k = 1; k < liveAt.length; k++) liveAt[k] - liveAt[k - 1]]..sort();
    expect(gaps.last, lessThan(400), reason: 'monitor gaps $gaps');
    await processingIdle(events);
    await sub.cancel();
    final ok = events
        .whereType<ProcessingEvent>()
        .where((e) => !e.busy && e.error.isEmpty)
        .map((e) => e.record)
        .toList();
    expect(ok, [for (var r = 1; r <= stored; r++) r]);
    expect(events.whereType<ProcessingEvent>().where((e) => e.error.isNotEmpty), isEmpty);
  });

  test('continuous measurement: the whole average at once is processed after STOP', () async {
    final s = await continuousSetup(execution: ExecutionMode.singleCore, atOnce: true, alg: 'TWM-WFFT');
    final events = <BackendEvent>[];
    final sub = b.events.listen(events.add);
    await b.startMeasurement(s);
    await Future<void>.delayed(const Duration(seconds: 3));
    await b.stopMeasurement();
    final fin = await b.events.firstWhere((e) => e is FinishedEvent) as FinishedEvent;
    await sub.cancel();
    expect(fin.error, isEmpty);
    expect([
      for (final e in events.whereType<ProcessingEvent>())
        if (e.error.isNotEmpty) '${e.record}: ${e.error}',
    ], isEmpty);
    final ri = await b.resultsInfo(fin.sessionPath);
    expect(ri.algorithms, ['TWM-WFFT']);
  });
}
