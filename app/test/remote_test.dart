import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/backend/remote_backend.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// Web/remote mode end-to-end: RemoteBackend -> HTTP/WebSocket -> TwmServer
/// -> LocalBackend -> simulated digitizer + GNU Octave.
void main() {
  test('remote measurement with processing', () async {
    final tmp = Directory.systemTemp.createTempSync('twm_remote');
    final local = LocalBackend(
      AppPaths.resolve(settingsFile: '${tmp.path}/s.json'),
    );
    final server = TwmServer(local, token: 'secret');
    await server.start(port: 0);
    final remote = await RemoteBackend.connect('http://127.0.0.1:${server.port}', token: 'secret');
    try {
      final s = await remote.loadSettings();
      s.digitizer.simulated.realtimeFactor = 0;
      s.digitizer.onClose = OnCloseAction.immediateReset;
      s.measurement
        ..folder = tmp.path
        ..nameBase = 'remote'
        ..samplesCount = 10000
        ..recordsCount = 2
        ..processingEnabled = true
        ..processing = ProcessingSetup(algorithmId: 'TWM-WRMS');
      await remote.saveSettings(s);
      expect((await remote.loadSettings()).measurement.nameBase, 'remote');

      final test = await remote.testDigitizer(s.digitizer);
      expect(test.ok, isTrue);
      expect(test.capabilities!.maxFs, 1e6);

      final events = <BackendEvent>[];
      final sub = remote.events.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 200)); // websocket connected
      await remote.startMeasurement(s);
      final fin =
          await remote.events.firstWhere((e) => e is FinishedEvent).timeout(const Duration(minutes: 2))
              as FinishedEvent;
      await sub.cancel();
      expect(fin.error, isEmpty);
      expect(events.whereType<WaveformEvent>(), isNotEmpty);
      expect(events.whereType<ProcessingEvent>().where((e) => !e.busy && e.error.isEmpty).length, 2);

      final info = await remote.resultsInfo(fin.sessionPath);
      expect(info.algorithms, ['TWM-WRMS']);
      final t = await remote.results(fin.sessionPath, 'TWM-WRMS', ResultViewConfig(resultId: 0));
      final rms = t.rows.firstWhere((r) => r.first.startsWith('rms'));
      expect(rms[1], startsWith('5.000'));

      final dir = await remote.listDir(tmp.path);
      expect(dir.entries.map((e) => e.name), contains('remote'));
      final wf = await remote.readRecord(fin.sessionPath, 1, 2, maxPoints: 500);
      expect(wf.channels.first.length, 500);

      // wrong token is rejected
      await expectLater(
        RemoteBackend.connect('http://127.0.0.1:${server.port}', token: 'x'),
        throwsA(isA<Exception>()),
      );
    } finally {
      await remote.dispose();
      await server.stop();
      await local.dispose();
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
