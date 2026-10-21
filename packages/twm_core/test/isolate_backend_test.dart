import 'dart:io';

import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

void main() {
  test('backend in isolate: measurement, events, server', () async {
    final tmp = Directory.systemTemp.createTempSync('twm_iso');
    final b = await IsolateBackend.spawn(
      home: '/home/e/papka_dlya_claude/twm_flutter',
      settingsFile: '${tmp.path}/s.json',
    );
    try {
      final s = await b.loadSettings();
      expect(s.octave.octprogPath, endsWith('octprog'));
      s.digitizer.simulated.realtimeFactor = 0;
      s.digitizer.onClose = OnCloseAction.immediateReset;
      s.measurement
        ..folder = tmp.path
        ..nameBase = 'iso'
        ..samplesCount = 5000
        ..recordsCount = 3;
      final events = <BackendEvent>[];
      final sub = b.events.listen(events.add);
      await b.startMeasurement(s);
      expect(b.measuring, isTrue);
      final fin = await b.events.firstWhere((e) => e is FinishedEvent).timeout(const Duration(seconds: 30));
      await sub.cancel();
      expect((fin as FinishedEvent).error, isEmpty);
      expect(b.measuring, isFalse);
      // live data is throttled (max 10/s): the last record is always shown
      final wf = events.whereType<WaveformEvent>();
      expect(wf, isNotEmpty);
      expect(wf.last.record, 3);
      final sum = await b.sessionSummary(fin.sessionPath);
      expect(sum.recordsPerGroup, [3]);
      // errors propagate
      await expectLater(b.readText('/nonexistent/file'), throwsA(isA<Exception>()));
      // server inside the backend isolate
      final st = await b.server('start', port: 0);
      expect(st['running'], isTrue);
      final c = await HttpClient().postUrl(Uri.parse('http://127.0.0.1:${st['port']}/api/measuring'));
      final r = await c.close();
      expect(r.statusCode, 200);
      await b.server('stop');
    } finally {
      await b.dispose();
      tmp.deleteSync(recursive: true);
    }
  });

  test('a dead backend isolate fails the calls instead of hanging', () async {
    final tmp = Directory.systemTemp.createTempSync('twm_iso_dead');
    final b = await IsolateBackend.spawn(home: '/home/e/papka_dlya_claude/twm_flutter', settingsFile: '${tmp.path}/s.json');
    try {
      final events = <BackendEvent>[];
      final sub = b.events.listen(events.add);
      // simulate a crash of the backend isolate
      b.debugKill();
      await expectLater(
        b.loadSettings().timeout(const Duration(seconds: 5)),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(events.whereType<FinishedEvent>().single.error, contains('stopped'));
    } finally {
      await b.dispose();
      tmp.deleteSync(recursive: true);
    }
  });
}
