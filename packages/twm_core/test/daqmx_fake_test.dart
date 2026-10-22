@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// cDAQ (NI 9238) driver through real FFI calls into a fake NI-DAQmx
/// library (test/fixtures/fake_daqmx.c, the C signatures of NIDAQmx.h).
void main() {
  // the fake library is built before the tests are declared (skip without a C compiler)
  final tmp = Directory.systemTemp.createTempSync('twm_fakedaqmx');
  final lib = '${tmp.path}/libfakedaqmx.so';
  final cc = Process.runSync('cc', ['-shared', '-fPIC', '-O2', '-o', lib, 'test/fixtures/fake_daqmx.c', '-lm']);
  final skip = cc.exitCode == 0 ? null : 'no C compiler for the fake DAQmx library: ${cc.stderr}';
  late final Pointer<Utf8> Function() fakeLog;
  setUpAll(() {
    DaqMx.load(lib);
    fakeLog = DynamicLibrary.open(lib).lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('fakeLog');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<void> measure(DigitizerConfig c, {required int n}) async {
    final fs = c.cdaq.fixedRate;
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: CdaqDigitizer(c),
      digitizerConfig: c,
      config: MeasurementConfig(
        fs: fs,
        samplesCount: n,
        folder: '${tmp.path}/m${DateTime.now().microsecondsSinceEpoch}',
        nameBase: 'cdaq',
      ),
      corrections: CorrectionsConfig(),
    ).run();
    final r = await SessionReader.open(IoFileStore(), session);
    final rec = await r.readRecord(1, 1);
    // the record starts where the stream was when it was initiated (time stamp)
    final start = (r.group(1).matrix('record relative timestamps [s]').first.first * fs).round();
    for (var ch = 0; ch < c.cdaq.channelIds.length; ch++) {
      final x = rec.channels[ch];
      expect(x.length, n);
      var maxErr = 0.0;
      for (var i = 0; i < n; i++) {
        maxErr = math.max(maxErr, (x[i] - 0.4 * math.sin(2 * math.pi * 50 * (start + i) / fs + ch)).abs());
      }
      // 24 bit codes of the +-0.5 V range: half an LSB
      expect(maxErr, lessThan(0.5 / (1 << 23)), reason: 'samples of channel ${ch + 1}');
    }
  }

  test('continuous task, interleaved samples, record cut from the stream', () async {
    final c = DigitizerConfig(type: DigitizerType.cdaq)
      ..cdaq.channelIds = [0, 1]
      ..cdaq.fixedRate = 50000;
    await measure(c, n: 25000);
    expect(
      fakeLog().toDartString().split(';'),
      containsAllInOrder([
        'AIVoltage(cDAQ1Mod1/ai0,cDAQ1Mod1/ai1,-1,-0.5,0.5,10348,null)',
        'Timing(,50000,10280,10123,1048576)',
        'Start',
      ]),
    );
  }, skip: skip);

  test('imported master clock sets the sample clock timebase after the timing (TWM)', () async {
    final c = DigitizerConfig(type: DigitizerType.cdaq)
      ..cdaq.channelIds = [0]
      ..cdaq.fixedRate = 50000
      ..cdaq.clockMode = CdaqClockMode.importMasterClock
      ..cdaq.clockSource = '/cDAQ1Mod2/ai/SampleClockTimebase'
      ..cdaq.extClockHz = 12.8e6;
    await measure(c, n: 5000);
    expect(
      fakeLog().toDartString().split(';'),
      containsAllInOrder([
        'Timing(,50000,10280,10123,1048576)',
        'TimebaseSrc(/cDAQ1Mod2/ai/SampleClockTimebase)',
        'TimebaseRate(1.28e+07)',
        'Start',
      ]),
    );
  }, skip: skip);
}
