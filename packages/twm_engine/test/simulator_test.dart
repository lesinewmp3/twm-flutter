import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// The simulator is the reference for checking the processing accuracy:
/// every sample must equal the exact formula within the quantization step.
void main() {
  test('simulated samples match the exact signal within 1 LSB (long record, 150 kHz)', () async {
    final cfg = DigitizerConfig()..type = DigitizerType.simulated;
    cfg.simulated
      ..realtimeFactor = 0
      ..maxFs = 1e9
      ..bits = 24
      ..channels = [
        SimChannelConfig(
          name: 'u',
          range: 10,
          noiseRms: 0,
          timeShift: 1.3e-6,
          harmonics: [SimHarmonic(50, 7.0710678, 0.1), SimHarmonic(150000, 0.05, -0.4)],
        ),
        SimChannelConfig(name: 'i', range: 1, noiseRms: 0, harmonics: [SimHarmonic(50, 0.5, -0.2)]),
      ];
    final d = SimulatedDigitizer(cfg);
    await d.initialize();
    // let the time since driver start grow (absolute phase reference)
    await Future<void>.delayed(const Duration(milliseconds: 30));
    const fs = 1e6, n = 3000000;
    await d.setup(fs: fs, samplesCount: n, trigger: TriggerConfig(), aperture: 0, ranges: const [10, 1]);
    await d.initiate();
    var worst = [0.0, 0.0];
    var got = 0;
    while (true) {
      final r = await d.fetch();
      final p = r.packet;
      if (p != null) {
        final aux = r.aux!;
        for (var c = 0; c < 2; c++) {
          final cc = cfg.simulated.channels[c];
          for (var i = 0; i < p.count; i += 7) {
            final k = p.offset + i;
            final t = aux.timestamps[c] + cc.timeShift + k / fs;
            var exact = 0.0;
            for (final h in cc.harmonics) {
              exact += h.amp * math.sin(2 * math.pi * h.freq * t + h.phase);
            }
            final e = (p.samples[i * 2 + c] * aux.gains[c] - exact).abs() / aux.gains[c];
            worst[c] = math.max(worst[c], e);
          }
        }
        got += p.count;
      }
      if (r.done) break;
    }
    expect(got, n);
    // only the 0.5 LSB rounding of the quantizer
    expect(worst[0], lessThan(0.5 + 1e-6), reason: 'channel u worst error ${worst[0]} LSB');
    expect(worst[1], lessThan(0.5 + 1e-6), reason: 'channel i worst error ${worst[1]} LSB');
  });
}
