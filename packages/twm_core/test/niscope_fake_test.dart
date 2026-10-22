@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// NI PXI-5922 driver through real FFI calls into a fake NI-SCOPE/NI-TClk
/// library (test/fixtures/fake_niscope.c, the C signatures of niScope.h):
/// argument passing, the niScope_wfmInfo layout (scaling, time stamps) and
/// the call sequences.
void main() {
  // the fake library is built before the tests are declared (skip without a C compiler)
  final tmp = Directory.systemTemp.createTempSync('twm_fakescope');
  final lib = '${tmp.path}/libfakeniscope.so';
  final cc = Process.runSync('cc', ['-shared', '-fPIC', '-O2', '-o', lib, 'test/fixtures/fake_niscope.c', '-lm']);
  final skip = cc.exitCode == 0 ? null : 'no C compiler for the fake NI-SCOPE library: ${cc.stderr}';
  late final Pointer<Utf8> Function(int) fakeLog;
  setUpAll(() {
    NiScopeLib.load(lib, lib);
    fakeLog = DynamicLibrary.open(
      lib,
    ).lookupFunction<Pointer<Utf8> Function(Uint32), Pointer<Utf8> Function(int)>('fakeLog');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  DigitizerConfig cfg(List<(String, int)> channels, {bool streaming = false}) =>
      DigitizerConfig(type: DigitizerType.niScope)
        ..onClose = OnCloseAction.immediateReset
        ..niScope.streaming = streaming
        ..niScope.channels = [
          for (final (r, id) in channels) NiScopeChannelConfig(resource: r, channelId: id, range: 1),
        ];

  /// Measures one record; checks the samples (fake: 1 kHz sine of 1 V, phase
  /// channel id + 2 * (session - 1), scaled by the gain and offset of
  /// niScope_wfmInfo) and returns the relative time stamps of the record.
  Future<List<double>> measure(DigitizerConfig c, {required double fs, required int n}) async {
    final session = await MeasurementEngine(
      store: IoFileStore(),
      digitizer: NiScopeDigitizer(c),
      digitizerConfig: c,
      config: MeasurementConfig(
        fs: fs,
        samplesCount: n,
        folder: '${tmp.path}/m${DateTime.now().microsecondsSinceEpoch}',
        nameBase: 'scope',
      ),
      corrections: CorrectionsConfig(),
    ).run();
    final r = await SessionReader.open(IoFileStore(), session);
    final rec = await r.readRecord(1, 1);
    final cards = [for (final ch in c.niScope.channels) ch.resource].toSet().toList();
    for (var k = 0; k < c.niScope.channels.length; k++) {
      final ch = c.niScope.channels[k];
      final phase = ch.channelId + 2.0 * cards.indexOf(ch.resource);
      final x = rec.channels[k];
      expect(x.length, n);
      var maxErr = 0.0;
      for (var i = 0; i < n; i++) {
        final code = (1e6 * math.sin(2 * math.pi * 1e3 * i / fs + phase)).round();
        maxErr = math.max(maxErr, (x[i] - (code * 1e-6 + 0.25e-6)).abs());
      }
      expect(maxErr, lessThan(1e-9), reason: 'samples of channel ${k + 1}');
    }
    return r.group(1).matrix('record relative timestamps [s]').first;
  }

  test('single shot: arguments, wfmInfo scaling and call sequence', () async {
    final stamps = await measure(cfg([('PXI1Slot2', 0), ('PXI1Slot2', 1)]), fs: 1e6, n: 100000);
    expect(stamps, [0, 0]);
    final log = fakeLog(1).toDartString();
    expect(
      log.split(';'),
      containsAllInOrder([
        'init(PXI1Slot2)',
        'Acquisition(0)',
        'Vertical(0,2,0,1,1,1)', // range peak-peak, offset, DC, probe, enabled
        'Chan(0,1e+06,-1)',
        'Vertical(1,2,0,1,1,1)',
        'Horizontal(1e+06,100000,0,1,1)',
        'SetString(1150002,VAL_NO_SOURCE)', // internal clock set explicitly
        'TrigImmediate',
        'Commit',
        'Initiate',
      ]),
    );
  }, skip: skip);

  test(
    'streaming of two cards (NI-TClk): continuous acquisition behind the read pointer',
    () async {
      // longer than the record buffer of the cards (1 Mi samples): only works when the reference
      // trigger never comes (software trigger, NI "Fetch Forever"); fake: in real time, 1.2 s
      final c = cfg([('PXI1Slot2', 0), ('PXI1Slot3', 0)], streaming: true);
      final stamps = await measure(c, fs: 1e6, n: 1200000);
      // time stamps of the record = of its first samples
      expect(stamps, [0, 0]);
      final master = fakeLog(1).toDartString().split(';'), slave = fakeLog(2).toDartString().split(';');
      expect(
        master,
        containsAllInOrder([
          'Horizontal(1e+06,1048576,0,1,1)',
          'SetInt(1150077,388)', // fetch relative to the read pointer
          'TrigSoftware(0,0)',
          'Commit',
          'TClkHomogeneous',
          'TClkSync(0)',
          'Initiate',
        ]),
      );
      expect(slave, containsAllInOrder(['TrigImmediate', 'Commit', 'TClkHomogeneous', 'Initiate']));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('PFI multiplexer: reference clock exported as TWM (Disable, Export, Commit)', () async {
    final d = NiScopeDigitizer(cfg([('PXI1Slot2', 0)]));
    await d.initialize();
    d.exportPfi(0, 'VAL_PFI_1');
    expect(fakeLog(1).toDartString(), contains('Disable;Export(100,,VAL_PFI_1);Commit;'));
    await d.close();
  }, skip: skip);
}
