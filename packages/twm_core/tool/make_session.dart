// Generates a simulated TWM measurement session (for manual testing).
// usage: dart run tool/make_session.dart <folder> [records]
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

Future<void> main(List<String> args) async {
  const repo = '/home/e/papka_dlya_claude/src/TWM/data/corrections';
  final dc = DigitizerConfig()..simulated.realtimeFactor = 0;
  final mc = MeasurementConfig(
    fs: 10000,
    samplesCount: 20000,
    recordsCount: args.length > 1 ? int.parse(args[1]) : 2,
    folder: args[0],
    nameBase: 'sim',
  );
  final corr = CorrectionsConfig(
    transducers: [
      TransducerConfig(path: '$repo/transducers/dummy.vd/dummy.info', highChannel: 1),
      TransducerConfig(path: '$repo/transducers/dummy.cs/dummy.info', type: TransducerType.shunt, highChannel: 2),
    ],
  );
  final s = await MeasurementEngine(
          store: IoFileStore(),
    digitizer: SimulatedDigitizer(dc),
    digitizerConfig: dc,
    config: mc,
    corrections: corr,
  ).run();
  print(s);
}
