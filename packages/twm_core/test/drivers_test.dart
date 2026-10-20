import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_core/src/drivers/niscope/niscope_lib.dart';
import 'package:twm_model/twm_model.dart';

void main() {
  registerHardwareDrivers();

  test('all digitizer types have a driver', () {
    for (final t in DigitizerType.values) {
      expect(DigitizerFactory.isAvailable(t), isTrue, reason: t.name);
    }
  });

  test('niScope wfmInfo struct layout (8 x 8 bytes with padding)', () {
    expect(sizeOf<WfmInfo>(), 64);
  });

  test('missing NI drivers give clear error', () async {
    for (final t in [DigitizerType.niScope, DigitizerType.cdaq]) {
      final d = DigitizerFactory.create(DigitizerConfig(type: t));
      await expectLater(d.initialize(), throwsA(predicate((e) => '$e'.contains('install NI'))), reason: t.name);
    }
  });

  test('ADS127 explains missing protocol', () async {
    final d = DigitizerFactory.create(DigitizerConfig(type: DigitizerType.ads127l21));
    await expectLater(d.initialize(), throwsA(predicate((e) => '$e'.contains('not public'))));
  });

  test('VISA library missing gives clear error', () async {
    await expectLater(
      InstrumentIoFactory.open('GPIB0::22::INSTR'),
      throwsA(predicate((e) => '$e'.contains('VISA library'))),
    );
  });

  test('Keysight DSO against emulator through the engine', () async {
    final tmp = Directory.systemTemp.createTempSync('twm_dso');
    final c = DigitizerConfig(type: DigitizerType.keysightDso, onClose: OnCloseAction.immediateReset)
      ..dso.visa = 'SIM::DSO::1';
    final mc = MeasurementConfig(fs: 100000, samplesCount: 2000, folder: tmp.path, nameBase: 'dso');
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: DigitizerFactory.create(c),
      digitizerConfig: c,
      config: mc,
      corrections: CorrectionsConfig(),
    ).run();
    final r = await SessionReader.open(IoFileStore(), session);
    expect(r.channelDescriptors.first, 'DSOS604A MY00000001, channel 1');
    final rec = await r.readRecord(1, 1);
    final peak = rec.channels[0].reduce((a, b) => a.abs() > b.abs() ? a : b).abs();
    expect(peak, closeTo(0.7, 0.01));
    expect(r.group(1).matrix('record relative timestamps [s]').first.first, -1e-6);
    tmp.deleteSync(recursive: true);
  });

  test('COM multiplexer requires VISA, dummy for simulator', () {
    final mux = MultiplexerConfig(enabled: true);
    expect(createMultiplexer(mux, SimulatedDigitizer(DigitizerConfig())), isA<DummyMultiplexer>());
    expect(
      createMultiplexer(mux, Hp3458aDigitizer(DigitizerConfig(type: DigitizerType.hp3458a))),
      isA<ComPortMultiplexer>(),
    );
  });
}
