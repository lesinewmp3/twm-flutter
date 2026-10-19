@Tags(['hardware'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// Real capture from the sound card of the test machine (ALSA / winmm).
void main() {
  registerHardwareDrivers();

  test('enumerate capture devices', () async {
    final d = DigitizerFactory.create(DigitizerConfig(type: DigitizerType.soundCard));
    final devs = await d.enumerateDevices();
    print(devs);
    expect(devs, contains('default'));
  });

  test('record 0.5 s stereo through the engine', () async {
    final tmp = Directory.systemTemp.createTempSync('twm_snd');
    final c = DigitizerConfig(type: DigitizerType.soundCard, onClose: OnCloseAction.immediateReset);
    final mc = MeasurementConfig(fs: 48000, samplesCount: 24000, recordsCount: 2, folder: tmp.path, nameBase: 's');
    final session = await MeasurementEngine(
      digitizer: DigitizerFactory.create(c),
      digitizerConfig: c,
      config: mc,
      corrections: CorrectionsConfig(),
    ).run().timeout(const Duration(seconds: 20));
    final r = await SessionReader.open(session);
    final rec = await r.readRecord(1, 2);
    expect(rec.channels.length, 2);
    expect(rec.fullLength, 24000);
    final m = rec.channels[0].fold<double>(0, (s, v) => s > v.abs() ? s : v.abs());
    print('peak ${m.toStringAsExponential(3)} V (mic/line input)');
    tmp.deleteSync(recursive: true);
  });
}
