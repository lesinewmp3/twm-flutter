import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// 3458A driver against the 3458A emulator (no hardware available).
void main() {
  registerHardwareDrivers();
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('twm_3458'));
  tearDown(() => tmp.deleteSync(recursive: true));

  DigitizerConfig cfg() => DigitizerConfig(type: DigitizerType.hp3458a)
    ..onClose = OnCloseAction.immediateReset
    ..hp3458a.channels = [
      DmmChannelConfig(visa: 'SIM::3458A::1', range: 1),
      DmmChannelConfig(visa: 'SIM::3458A::2', range: 1),
    ];

  test('identification from CALSTR', () async {
    final d = DigitizerFactory.create(cfg());
    await d.initialize();
    expect(d.channelIdns, ['HP3458A, sn. MY45053091', 'HP3458A, sn. MY45053092']);
    final c = cfg()..hp3458a.idnMode = Dmm3458IdnMode.sequential;
    final d2 = DigitizerFactory.create(c);
    await d2.initialize();
    expect(d2.channelIdns.last, 'HP3458A, channel 2');
    await d.close();
    await d2.close();
  });

  test('aperture vs sampling period check', () async {
    final d = DigitizerFactory.create(cfg());
    await d.initialize();
    expect(
      () => d.setup(fs: 50000, samplesCount: 100, trigger: TriggerConfig(), aperture: 100e-6, ranges: [1, 1]),
      throwsA(isA<DigitizerException>()),
    );
    await d.close();
  });

  test('memory limit without streaming', () async {
    final d = DigitizerFactory.create(cfg());
    await d.initialize();
    expect(
      () => d.setup(fs: 10000, samplesCount: 200000, trigger: TriggerConfig(), aperture: 1e-6, ranges: [1, 1]),
      throwsA(isA<DigitizerException>()),
    );
    await d.close();
  });

  test('master-slave measurement through the engine', () async {
    final c = cfg();
    final d = DigitizerFactory.create(c) as Hp3458aDigitizer;
    final mc = MeasurementConfig(
      fs: 10000,
      aperture: 1e-6,
      samplesCount: 5000,
      recordsCount: 2,
      folder: tmp.path,
      nameBase: 'dmm',
    );
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: d,
      digitizerConfig: c,
      config: mc,
      corrections: CorrectionsConfig(),
    ).run();
    final r = await SessionReader.open(IoFileStore(), session);
    expect(r.channelDescriptors, ['HP3458A, sn. MY45053091', 'HP3458A, sn. MY45053092']);
    final h = r.header;
    expect(h.text('synchronization mode'), 'MASTER-SLAVE, MASTER clocked by TIMER');
    expect(h.text('sampling mode'), 'DCV');
    final g = r.group(1);
    expect(g.number('bit resolution'), 16);
    expect(g.vector('record time increments [s]').first, closeTo(1e-4, 1e-15));
    final rec = await r.readRecord(1, 1);
    // emulator: channel 1 = 0.7 V pk @ 50 Hz (+1 % 3rd harmonic)
    final rms = math.sqrt(rec.channels[0].fold<double>(0, (s, v) => s + v * v) / rec.channels[0].length);
    expect(rms, closeTo(math.sqrt(0.7 * 0.7 / 2 + 0.007 * 0.007 / 2), 1e-4));
  });

  test('command sequence follows TPQA (master/slave roles)', () async {
    final c = cfg();
    final d = DigitizerFactory.create(c);
    await d.initialize();
    await d.setup(fs: 10000, samplesCount: 100, trigger: TriggerConfig(), aperture: 1e-6, ranges: [1, 1]);
    await d.initiate();
    // read whole record
    var done = false;
    while (!done) {
      done = (await d.fetch()).done;
    }
    await d.cleanup();
    await d.close();
    // inspect emulator logs through a fresh session of the same resources
  });

  test('emulator log of master and slave', () async {
    final m = Emu3458a('SIM::3458A::1');
    final s = Emu3458a('SIM::3458A::2');
    var idx = 0;
    InstrumentIoFactory.registerEmulator('3458X', (r) async => [m, s][idx++]);
    final c = cfg()
      ..hp3458a.channels = [
        DmmChannelConfig(visa: 'SIM::3458X::1', range: 10),
        DmmChannelConfig(visa: 'SIM::3458X::2', range: 1),
      ];
    final d = Hp3458aDigitizer(c);
    await d.initialize();
    await d.setup(
      fs: 10000,
      samplesCount: 100,
      trigger: TriggerConfig(source: TriggerSource.level, level: 0.1),
      aperture: 1e-6,
      ranges: [10, 1],
    );
    await d.initiate();
    expect(
      m.log,
      containsAllInOrder([
        'PRESET DIG',
        'FUNC DCV,10.0',
        'TARM HOLD',
        'TRIG LEVEL',
        'SLOPE POS',
        'NRDGS 100,TIMER',
        'TARM SGL',
      ]),
    );
    expect(s.log, containsAllInOrder(['PRESET DIG', 'FUNC DCV,1.0', 'TRIG EXT', 'NRDGS 100,EXT', 'TARM SGL']));
    expect(m.log, contains('EXTOUT APER,NEG'));
    expect(m.log, contains('MFORMAT SINT'));
    await d.close();
    expect(m.log, contains('PRESET NORM'));
  });
}
