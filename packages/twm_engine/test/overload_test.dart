import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// A clipped signal makes every result wrong (a 1.41x overrange gave -17 %
/// current in the validation): the engine must stop with an error.
void main() {
  Future<(String?, List<String>)> run({required bool ignore}) async {
    final dc = DigitizerConfig()
      ..type = DigitizerType.simulated
      ..ignoreOverload = ignore;
    dc.simulated
      ..realtimeFactor = 0
      ..channels = [
        SimChannelConfig(name: 'u', range: 10, harmonics: [SimHarmonic(50, 7)]),
        SimChannelConfig(name: 'i', range: 1, harmonics: [SimHarmonic(50, 1.41)]),
      ];
    final e = MeasurementEngine(
      store: MemoryFileStore(),
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: MeasurementConfig(fs: 10000, samplesCount: 10000, recordsCount: 2, folder: '/m', nameBase: 'o'),
      corrections: CorrectionsConfig(),
    );
    final status = <String>[];
    final sub = e.events.listen((ev) {
      if (ev is MeasStatus) status.add(ev.message);
    });
    String? error;
    try {
      await e.run();
    } on DigitizerException catch (x) {
      error = x.message;
    }
    await sub.cancel();
    return (error, status);
  }

  test('overload stops the measurement', () async {
    final (error, _) = await run(ignore: false);
    expect(error, contains('Overload'));
    expect(error, contains('channel(s) 2'));
  });

  test('ignored overload only warns', () async {
    final (error, status) = await run(ignore: true);
    expect(error, isNull);
    expect(status.where((s) => s.contains('overload')), isNotEmpty);
  });
}
