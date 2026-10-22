@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// 3458A driver through real VISA FFI calls into a fake VISA library
/// (test/fixtures/fake_visa.c: sessions behave like 3458A DMMs producing
/// readings in real time; without reading memory only a few readings are
/// buffered, a slow controller makes an overrun).
void main() {
  // the fake library is built before the tests are declared (skip without a C compiler)
  final tmp = Directory.systemTemp.createTempSync('twm_fakevisa');
  final lib = '${tmp.path}/libfakevisa.so';
  final cc = Process.runSync('cc', [
    '-shared',
    '-fPIC',
    '-O2',
    '-o',
    lib,
    'test/fixtures/fake_visa.c',
    '-lpthread',
    '-lm',
  ]);
  final skip = cc.exitCode == 0 ? null : 'no C compiler for the fake VISA library: ${cc.stderr}';
  late final int Function() readCalls;
  setUpAll(() {
    VisaLib.load(lib);
    readCalls = DynamicLibrary.open(lib).lookupFunction<Int64 Function(), int Function()>('fakeReadCalls');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  DigitizerConfig cfg(List<String> visa, {required bool streaming}) => DigitizerConfig(type: DigitizerType.hp3458a)
    ..onClose = OnCloseAction.immediateReset
    ..hp3458a.idnMode = Dmm3458IdnMode.sequential
    ..hp3458a.streaming = streaming
    ..hp3458a.memory = Dmm3458Memory.option001
    ..hp3458a.channels = [for (final v in visa) DmmChannelConfig(visa: v, range: 1)];

  /// Measures one record, checks the samples of each DMM (fake: sine 1 V,
  /// phase = VISA session number 2, 3, ...) and returns the VISA reads made.
  Future<int> measure(DigitizerConfig c, {required double fs, required int n}) async {
    final reads0 = readCalls();
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: Hp3458aDigitizer(c),
      digitizerConfig: c,
      config: MeasurementConfig(
        fs: fs,
        aperture: 1e-6,
        samplesCount: n,
        folder: '${tmp.path}/m${DateTime.now().microsecondsSinceEpoch}',
        nameBase: 'dmm',
      ),
      corrections: CorrectionsConfig(),
    ).run();
    final rec = await (await SessionReader.open(IoFileStore(), session)).readRecord(1, 1);
    for (var ch = 0; ch < c.hp3458a.channels.length; ch++) {
      final x = rec.channels[ch];
      expect(x.length, n);
      var maxErr = 0.0;
      for (var i = 0; i < n; i++) {
        final code = (10000 * math.sin(2 * math.pi * 50 * i / fs + ch + 2)).round();
        maxErr = math.max(maxErr, (x[i] - code * 1e-4).abs());
      }
      expect(maxErr, lessThan(1e-9), reason: 'samples of DMM ${ch + 1}');
    }
    return readCalls() - reads0;
  }

  test('memory mode: readings transferred with END OFF (a few VISA reads, not one per reading)', () async {
    final reads = await measure(cfg(['GPIB0::22::INSTR', 'GPIB0::23::INSTR'], streaming: false), fs: 20000, n: 20000);
    // with END ALWAYS every reading would end the read: >= 40000 reads
    expect(reads, lessThan(200));
  }, skip: skip);

  test(
    'streaming: DMMs read in parallel keep up without an overrun',
    () async {
      // 2 s at 20 kSa/s, the fake DMM buffers only 64 readings (3 ms)
      await measure(cfg(['GPIB0::22::INSTR', 'GPIB1::23::INSTR'], streaming: true), fs: 20000, n: 40000);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
