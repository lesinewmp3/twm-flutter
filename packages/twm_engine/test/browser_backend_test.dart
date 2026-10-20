import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// Complete browser mode workflow on the in-memory store.
void main() {
  test('result number formatting', () {
    expect(DartProcessor.fmt(50.0), '50');
    expect(DartProcessor.fmt(50.1), '50.1');
    expect(DartProcessor.fmt(7.071067812), '7.07106781');
    expect(DartProcessor.fmt(1200.0), '1200');
  });

  test('measure, process by Dart algorithm, view results, zip round trip', () async {
    final store = MemoryFileStore();
    await store.writeText(
      '/corrections/transducers/u/u.info',
      'type:: divider\nname:: test divider\nnominal ratio:: 10\n',
    );
    await store.writeText(
      '/corrections/transducers/i/i.info',
      'type:: shunt\nname:: test shunt\nnominal ratio:: 0.1\n',
    );
    String? saved;
    final b = BrowserBackend(store, loadSettingsText: () async => saved, saveSettingsText: (t) async => saved = t);
    final s = await b.loadSettings();
    expect(s.measurement.folder, '/measurements');
    s.digitizer.simulated.realtimeFactor = 0;
    s.measurement
      ..samplesCount = 10000
      ..recordsCount = 2
      ..processingEnabled = true
      ..processing = ProcessingSetup(algorithmId: 'TWM-PWRTDI');
    s.corrections.transducers = [
      TransducerConfig(path: '/corrections/transducers/u/u.info', highChannel: 1),
      TransducerConfig(path: '/corrections/transducers/i/i.info', type: TransducerType.shunt, highChannel: 2),
    ];
    await b.saveSettings(s);
    expect((await b.loadSettings()).measurement.recordsCount, 2);

    final events = <BackendEvent>[];
    final sub = b.events.listen(events.add);
    await b.startMeasurement(s);
    final fin = await b.events.firstWhere((e) => e is FinishedEvent) as FinishedEvent;
    await sub.cancel();
    expect(fin.error, isEmpty);
    expect(events.whereType<ProcessingEvent>().where((e) => !e.busy && e.error.isEmpty).length, 2);

    final info = await b.resultsInfo(fin.sessionPath);
    expect(info.algorithms, ['TWM-PWRTDI']);
    expect(info.channels, ['L1']);
    final t = await b.results(fin.sessionPath, 'TWM-PWRTDI', ResultViewConfig());
    final p = t.rows.firstWhere((r) => r.first == 'P[L1]');
    // simulator: u 7.07 Vpk @50 Hz x divider 10, i 0.5 Apk x (1/0.1), phase 0.2 rad
    expect(double.parse(p[1]), closeTo(70.710678 * 5 / 2 * 0.98006658, 0.05));
    expect(t.header.take(3), ['', 'avg', 'ua']);

    // batch processing with another algorithm
    await b.processRecords(fin.sessionPath, ProcessingSetup(algorithmId: 'TWM-PSFE'), group: 1, records: [1, 2]);
    final i2 = await b.resultsInfo(fin.sessionPath, algorithm: 'TWM-PSFE');
    expect(i2.algorithms, containsAll(['TWM-PWRTDI', 'TWM-PSFE']));
    final d = await b.resultData(fin.sessionPath, 'TWM-PSFE', ResultViewConfig(resultId: 0));
    expect(d.channels.first.firstWhere((q) => q.name == 'f').value.first, closeTo(50, 1e-6));

    // download / upload as zip
    final zip = await b.exportZip(fin.sessionPath);
    final store2 = MemoryFileStore();
    final b2 = BrowserBackend(store2);
    final imported = await b2.importZip(zip, '/measurements');
    expect(imported.single, '/measurements/meas_001/session.info');
    final sum = await b2.sessionSummary(imported.single);
    expect(sum.recordsPerGroup, [2]);
    expect((await b2.resultsInfo(imported.single)).algorithms, contains('TWM-PSFE'));
  });

  test('coherent sampling search', () async {
    final b = BrowserBackend(MemoryFileStore());
    final r = await b.findCoherent(50.3, 0.5, 2, {'fs_step': 1e-6, 'fs_min': 10000.0, 'fs_rel_tol': 0.05}, 1e-9, 5);
    expect((r.n / r.fs * 50.3 - (r.n / r.fs * 50.3).round()).abs(), lessThan(1e-6));
    expect(r.fs, inInclusiveRange(10000, 10500));
  });
}
