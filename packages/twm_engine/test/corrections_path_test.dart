import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// The corrections panel stores transducer paths relative to the root with
/// DOS separators (as TWM does): 'dummy.vd\dummy.info'. On Linux the
/// measurement failed with "Correction file not found".
void main() {
  test('relative transducer path with DOS separators works on POSIX', () async {
    final store = MemoryFileStore();
    await store.writeText('/c/transducers/dummy.vd/dummy.info', 'type:: divider\nname:: d\nnominal ratio:: 1.0\n');
    await store.writeText('/c/transducers/dummy.cs/dummy.info', 'type:: shunt\nname:: s\nnominal ratio:: 1.0\n');
    final dc = DigitizerConfig()..type = DigitizerType.simulated;
    dc.simulated.realtimeFactor = 0;
    final session = await MeasurementEngine(
      store: store,
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: MeasurementConfig(fs: 10000, samplesCount: 1000, recordsCount: 1, folder: '/m', nameBase: 'c'),
      corrections: CorrectionsConfig(
        transducersRoot: '/c/transducers',
        transducers: [
          TransducerConfig(path: r'dummy.vd\dummy.info', highChannel: 1),
          TransducerConfig(path: r'dummy.cs\dummy.info', type: TransducerType.shunt, highChannel: 2),
        ],
      ),
    ).run();
    expect(await store.exists('/m/c/TRANSDUCERS/T01/dummy.info'), isTrue, reason: session);
    expect(await store.exists('/m/c/TRANSDUCERS/T02/dummy.info'), isTrue);
  });
}
