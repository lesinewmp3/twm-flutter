import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// The whole measurement runs on the in-memory store (browser mode).
void main() {
  test('memory store basics', () async {
    final s = MemoryFileStore();
    await s.writeText('/a/b/c.txt', 'hello');
    expect(await s.isDirectory('/a/b'), isTrue);
    expect(await s.readText('/a/b/c.txt'), 'hello');
    await s.appendText('/a/b/c.txt', '!');
    expect(await s.readText('/a/b/c.txt'), 'hello!');
    final sink = await s.openSink('/x.bin');
    await sink.add(Uint8List.fromList([1, 2, 3, 4]));
    await sink.writeAt(1, Uint8List.fromList([9]));
    await sink.close();
    expect(await s.readBytes('/x.bin'), [1, 9, 3, 4]);
    await s.copyTree('/a', '/copy');
    expect(await s.readText('/copy/b/c.txt'), 'hello!');
    expect((await s.list('/', recursive: true)).where((e) => !e.isDir).length, 3);
    await s.delete('/a', recursive: true);
    expect(await s.exists('/a/b/c.txt'), isFalse);
  });

  test('simulated measurement into memory store', () async {
    final store = MemoryFileStore();
    await store.writeText('/corr/dummy/dummy.info', 'type:: divider\nname:: dummy\nnominal ratio:: 1\n');
    final dc = DigitizerConfig()..simulated.realtimeFactor = 0;
    final mc = MeasurementConfig(fs: 10000, samplesCount: 2000, recordsCount: 2, folder: '/sessions', nameBase: 'm');
    final session = await MeasurementEngine(
      store: store,
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: mc,
      corrections: CorrectionsConfig(transducers: [TransducerConfig(path: '/corr/dummy/dummy.info')]),
    ).run();
    expect(session, '/sessions/m/session.info');
    expect(await store.exists('/sessions/m/TRANSDUCERS/T01/dummy.info'), isTrue);
    final r = await SessionReader.open(store, session);
    expect(r.repetitions(1), 2);
    final rec = await r.readRecord(1, 2);
    final rms = math.sqrt(rec.channels[0].fold<double>(0, (a, v) => a + v * v) / rec.channels[0].length);
    expect(rms, closeTo(math.sqrt(7.0710678 * 7.0710678 / 2 + 0.07 * 0.07 / 2), 1e-3));
    expect(await SessionWriter.collidingFiles(store, '/sessions/m'), contains('RAW/G0001-A0002.mat'));
    await SessionWriter.clearSession(store, '/sessions/m');
    expect(await SessionWriter.collidingFiles(store, '/sessions/m'), isEmpty);
  });
}
