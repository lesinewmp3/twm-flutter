import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// Viewing a long record with fast content (PFC switching ripple): the
/// decimated waveform must keep the ripple amplitude (envelope) and the
/// spectrum must be computed from all samples (no aliased lines).
void main() {
  test('120 kHz ripple at 2 MSa/s: envelope keeps amplitude, spectrum peak at 120 kHz', () async {
    final store = MemoryFileStore();
    final dc = DigitizerConfig()..type = DigitizerType.simulated;
    dc.simulated
      ..realtimeFactor = 0
      ..maxFs = 1e9
      ..channels = [
        SimChannelConfig(name: 'i', range: 1, noiseRms: 0, harmonics: [SimHarmonic(50, 0.5), SimHarmonic(120000, 0.1)]),
      ];
    final session = await MeasurementEngine(
      store: store,
      digitizer: SimulatedDigitizer(dc),
      digitizerConfig: dc,
      config: MeasurementConfig(fs: 2e6, samplesCount: 400000, recordsCount: 1, folder: '/m', nameBase: 'r'),
      corrections: CorrectionsConfig(),
    ).run();

    final w = await readRecordOf(store, session, 1, 1, 2000);
    expect(w.channels.first.length, lessThanOrEqualTo(2000));
    final y = w.channels.first;
    final peak = y.reduce(math.max), low = y.reduce(math.min);
    expect(peak, closeTo(0.6, 2e-3), reason: '50 Hz + ripple crest kept');
    expect(low, closeTo(-0.6, 2e-3));

    final sp = await recordSpectrumOf(store, session, 1, 1, WindowType.flatTop, 1 << 30);
    final a = sp.amplitudes.first;
    var kmax = 1000; // above 50 Hz region
    for (var k = 1000; k < a.length; k++) {
      if (a[k] > a[kmax]) kmax = k;
    }
    expect(kmax * sp.df, closeTo(120000, 2 * sp.df));
    expect(a[kmax], closeTo(0.1, 1e-4));
  });
}
