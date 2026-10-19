import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

const twmRepo = '/home/e/papka_dlya_claude/src/TWM';

double rms(List<double> x) =>
    math.sqrt(x.fold<double>(0, (s, v) => s + v * v) / x.length);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('twm_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  DigitizerConfig simConfig() => DigitizerConfig()
    ..simulated.realtimeFactor = 0
    ..simulated.channels.first.noiseRms = 0;

  test('simulated measurement creates valid TWM session', () async {
    final dc = simConfig();
    final mc = MeasurementConfig(
      fs: 10000,
      samplesCount: 2000,
      recordsCount: 3,
      folder: tmp.path,
      nameBase: 'meas_%id%',
      measurementId: 7,
      comment: 'line 1\nline 2',
    );
    final corr = CorrectionsConfig(
      digitizerPath: '',
      transducers: [
        TransducerConfig(
            path: '$twmRepo/data/corrections/transducers/dummy.vd/dummy.info',
            type: TransducerType.divider,
            highChannel: 1),
        TransducerConfig(
            path: '$twmRepo/data/corrections/transducers/dummy.cs/dummy.info',
            type: TransducerType.shunt,
            highChannel: 2),
      ],
    );
    expect(corr.validate(2), isEmpty);
    final dig = SimulatedDigitizer(dc);
    final engine = MeasurementEngine(
        digitizer: dig, digitizerConfig: dc, config: mc, corrections: corr);
    final events = <MeasEvent>[];
    engine.events.listen(events.add);
    final session = await engine.run();
    expect(session, p.join(tmp.path, 'meas_007', 'session.info'));
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<MeasRecordStored>().length, 3);
    expect(events.whereType<MeasRecordData>().length, 3);
    expect(events.last, isA<MeasFinished>());

    // header content as expected by tpq_load_record.m
    final h = Info.parse(File(session).readAsStringSync());
    expect(h.number('channels count'), 2);
    expect(h.text('sample data format'), 'mat-v4');
    expect(h.number('groups count'), 1);
    expect(h.textList('measurement comment'), ['line 1', 'line 2']);
    final g = h.section('measurement group 1');
    expect(g.number('repetitions count'), 3);
    expect(g.number('samples count'), 2000);
    expect(g.textList('record sample data files').last, 'RAW\\G0001-A0003.mat');
    expect(g.matrix('record sample data gains [V]').length, 3);
    expect(g.matrix('record sample data gains [V]').first.length, 2);
    expect(g.vector('aperture [s]').length, 3);
    final c = h.section('measurement setup configuration');
    expect(c.textList('transducer paths'),
        ['TRANSDUCERS\\T01\\dummy.info', 'TRANSDUCERS\\T02\\dummy.info']);
    expect(c.matrix('transducer to digitizer channels mapping'), [
      [1, 0],
      [2, 0]
    ]);
    expect(File(p.join(tmp.path, 'meas_007', 'TRANSDUCERS', 'T02', 'dummy.info')).existsSync(),
        isTrue);

    // data read back
    final rd = await SessionReader.open(session);
    expect(rd.repetitions(1), 3);
    final rec = await rd.readRecord(1, 2);
    expect(rec.channels.length, 2);
    expect(rec.channels[0].length, 2000);
    // u: 7.0710678 V pk @50 Hz + 0.07 V @150 Hz -> rms ~ 5.000245
    final expected = math.sqrt(7.0710678 * 7.0710678 / 2 + 0.07 * 0.07 / 2);
    expect(rms(rec.channels[0]), closeTo(expected, 1e-4));
    expect(rec.ts, closeTo(1e-4, 1e-15));
  });

  test('sub-records and multiplexer write offsets', () async {
    final dc = simConfig()
      ..multiplexer.enabled = true
      ..multiplexer.delayAfterSwitch = 0
      ..multiplexer.delayBeforeSwitch = 0;
    final mc = MeasurementConfig(
        fs: 1000, samplesCount: 100, recordsCount: 1, subRecordsCount: 2,
        folder: tmp.path, nameBase: 'mux');
    final mux = DummyMultiplexer(dc.multiplexer);
    final engine = MeasurementEngine(
        digitizer: SimulatedDigitizer(dc),
        digitizerConfig: dc,
        config: mc,
        corrections: CorrectionsConfig(),
        multiplexer: mux);
    final session = await engine.run();
    final h = Info.parse(File(session).readAsStringSync());
    expect(h.number('multiplexer enabled'), 1);
    expect(h.number('multiplexer sequence cycles'), 2);
    final g = h.section('measurement group 1');
    expect(g.matrix('sub-record sample offsets'), [
      [0, 100, 200, 300]
    ]);
    expect(g.vector('record samples counts'), [400]);
    expect(mux.selected, 'B');
  });

  test('qwtb.info processing header', () async {
    final ps = ProcessingSetup(algorithmId: 'TWM-PWRTDI', parameters: [
      AlgorithmParameter('f_est', ['50']),
      AlgorithmParameter('window', ['flattop']),
      AlgorithmParameter('empty', ['']),
    ], uncertainty: UncertaintyMode.guf);
    await SessionWriter.writeQwtbSetup(tmp.path, ps);
    final q = Info.parse(File(p.join(tmp.path, 'qwtb.info')).readAsStringSync())
        .section('QWTB processing setup');
    expect(q.text('algorithm id'), 'TWM-PWRTDI');
    expect(q.text('uncertainty mode'), 'guf');
    expect(q.textList('list of parameter names'), ['f_est', 'window']);
    expect(q.textList('window'), ['flattop']);
  });

  test('stop aborts continuous acquisition', () async {
    final dc = simConfig()..simulated.realtimeFactor = 1;
    final mc = MeasurementConfig(
        fs: 1000, samplesCount: 100, continuous: true, saveRecords: false, folder: tmp.path);
    final engine = MeasurementEngine(
        digitizer: SimulatedDigitizer(dc), digitizerConfig: dc, config: mc,
        corrections: CorrectionsConfig());
    var n = 0;
    engine.events.listen((e) {
      if (e is MeasRecordData && ++n == 3) engine.stop();
    });
    await engine.run().timeout(const Duration(seconds: 5));
    expect(n, greaterThanOrEqualTo(3));
    expect(tmp.listSync(), isEmpty);
  });
}
