import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// UPS transfer simulated end to end: simulator event -> engine -> on-line
/// analysis must report the duration of the interruption.
void main() {
  test('simulated 3.7 ms transfer with 30 deg phase jump is measured', () async {
    final dc = DigitizerConfig()..type = DigitizerType.simulated;
    dc.simulated
      ..realtimeFactor = 0
      ..channels = [
        SimChannelConfig(
          name: 'u',
          range: 10,
          harmonics: [SimHarmonic(50, 3.25), SimHarmonic(150, 0.08, 0.3)],
          event: SimEvent(start: 0.1234, duration: 0.0037, phaseJump: math.pi / 6),
        ),
        SimChannelConfig(name: 'i', range: 1, harmonics: [SimHarmonic(50, 0.5, -0.2)]),
      ];
    final settings = AppSettings()
      ..online.transferAnalysis = true
      ..digitizer = dc;
    final out = <BackendEvent>[];
    final mapper = MeasEventMapper(MemoryFileStore(), settings, out.add);
    final engine = MeasurementEngine(
      store: MemoryFileStore(),
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: MeasurementConfig(fs: 20000, samplesCount: 6000, recordsCount: 1, folder: '/m', nameBase: 't'),
      corrections: CorrectionsConfig(),
    );
    final sub = engine.events.listen(mapper.handle);
    await engine.run();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    final r = OnlineResult.fromJson(out.whereType<WaveformEvent>().last.online!);
    double q(String n) => r.quantities.firstWhere((x) => x.name == n).value;
    // ignore: avoid_print
    print([for (final x in r.quantities) '${x.name}=${x.value}'].join(', '));
    expect(q('Event duration u1'), closeTo(3.7, 0.06));
    expect(q('Event start u1'), closeTo(123.4, 0.06));
    expect(q('Phase jump u1'), closeTo(30, 0.5));
    expect(q('Event depth u1'), lessThan(5));
    // the current channel (no event) is not analysed as a voltage? (no transducers: both are u)
    expect(q('Event duration u2'), 0);
  });
}
