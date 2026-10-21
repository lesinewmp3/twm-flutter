// Timing of the simulated digitizer and the record writer.
// dart run tool/bench_sim.dart
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

Future<void> main() async {
  final cfg = DigitizerConfig()..type = DigitizerType.simulated;
  cfg.simulated
    ..realtimeFactor = 0
    ..maxFs = 1e9;
  final d = SimulatedDigitizer(cfg);
  await d.initialize();
  for (final n in [2000000, 10000000]) {
    await d.setup(fs: n.toDouble(), samplesCount: n, trigger: TriggerConfig(), aperture: 0, ranges: const []);
    await d.initiate();
    final store = MemoryFileStore();
    final w = await RecordFileWriter.create(store, '/r.mat', cfg.simulated.channels.length);
    final sw = Stopwatch()..start();
    var gen = Duration.zero, wr = Duration.zero;
    while (true) {
      final t = Stopwatch()..start();
      final r = await d.fetch();
      gen += t.elapsed;
      t.reset();
      if (r.packet != null) await w.write(r.packet!);
      wr += t.elapsed;
      if (r.done) break;
    }
    await w.close();
    print('n=$n: generate ${gen.inMilliseconds} ms, write ${wr.inMilliseconds} ms, total ${sw.elapsedMilliseconds} ms');
  }
}
