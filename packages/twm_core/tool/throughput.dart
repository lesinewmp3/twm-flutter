// Throughput of the acquisition pipeline without the simulator's signal
// generation: a synthetic digitizer hands out ready blocks either at once
// (maximum rate) or paced like a streaming digitizer (e.g. PXI-5922 at
// 15 MSa/s), and the engine stores them to disk with the live views on.
// For the paced runs the backlog (data the digitizer has produced but the
// engine has not fetched yet) must stay bounded.
//
//   dart run tool/throughput.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

class FastDigitizer extends VirtualDigitizer {
  final bool int16;
  final double paceFs; // 0 = as fast as fetched
  final int block;
  FastDigitizer(super.config, {required this.int16, this.paceFs = 0, this.block = 262144});

  bool _open = false;
  double _fs = 1e6;
  int _n = 0, _pos = 0;
  final _clock = Stopwatch();
  late Int32List _data;
  int maxBacklog = 0;

  @override
  bool get isOpen => _open;

  @override
  Future<void> initialize({bool reset = false}) async {
    _open = true;
    channelIdns = ['fast ch1', 'fast ch2'];
    // a 50 Hz sine + ripple pattern, reused for every block
    _data = Int32List(block * 2);
    final full = int16 ? 30000 : 4000000;
    for (var i = 0; i < block; i++) {
      final v = math.sin(2 * math.pi * i / 4096) * 0.7 + 0.05 * math.sin(2 * math.pi * i / 17);
      _data[2 * i] = (v * full).round();
      _data[2 * i + 1] = (0.5 * v * full).round();
    }
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) => DigitizerCapabilities(
    maxSamplesCount: 1 << 40,
    maxFs: 1e10,
    minFs: 1,
    fsStep: 0,
    channelsCount: 2,
    hasLevelTrig: false,
    hasExtTrig: false,
    hasAperture: false,
    aperMin: 0,
    aperMax: 0,
    hasRanges: false,
    ranges: const [1],
  );

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    _fs = fs;
    _n = samplesCount;
  }

  @override
  Future<void> initiate() async {
    _pos = 0;
    _clock
      ..reset()
      ..start();
  }

  @override
  Future<FetchResult> fetch() async {
    var avail = _n;
    if (paceFs > 0) {
      avail = math.min(_n, (_clock.elapsedMicroseconds * 1e-6 * paceFs).floor());
      maxBacklog = math.max(maxBacklog, avail - _pos);
      if (avail - _pos <= 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return const FetchResult(status: DigitizerStatus(sampling: true));
      }
    }
    final count = math.min(block, avail - _pos);
    final samples = count == block ? _data : Int32List.sublistView(_data, 0, count * 2);
    final pk = DataPacket(samples, 2, _pos, isInt16: int16);
    _pos += count;
    final done = _pos >= _n;
    final g = 1 / (int16 ? 32768 : 8388608);
    return FetchResult(
      packet: pk,
      aux: AuxData(gains: [g, g], offsets: const [0, 0], timestamps: const [0, 0], increment: 1 / _fs),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  @override
  Future<void> abort() async {}
  @override
  Future<void> cleanup() async {}
  @override
  Future<void> close({bool resetToPreset = true}) async => _open = false;
  @override
  Future<void> selfCalibrate() async {}
  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: _n,
    channelsCount: 2,
    fs: _fs,
    ranges: const [1, 1],
    trigger: TriggerConfig(),
    isInt16: int16,
    bitResolution: int16 ? 16 : 24,
    fullScaleCode: int16 ? 32767 : 8388607,
  );
  @override
  String info() => 'fast synthetic digitizer';
}

Future<void> run(String name, {required double fs, required int n, required bool int16, double pace = 0}) async {
  final tmp = Directory.systemTemp.createTempSync('twm_tp');
  final dc = DigitizerConfig()..type = DigitizerType.simulated;
  final dig = FastDigitizer(dc, int16: int16, paceFs: pace);
  final mapperEvents = <BackendEvent>[];
  final s = AppSettings();
  final mapper = MeasEventMapper(IoFileStore(), s, mapperEvents.add);
  final engine = MeasurementEngine(
    store: IoFileStore(),
    digitizer: dig,
    digitizerConfig: dc,
    config: MeasurementConfig(fs: fs, samplesCount: n, recordsCount: 1, folder: tmp.path, nameBase: 'tp'),
    corrections: CorrectionsConfig(),
    monitorWindow: 0.08,
  );
  final sub = engine.events.listen(mapper.handle);
  final sw = Stopwatch()..start();
  final session = await engine.run();
  sw.stop();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await sub.cancel();
  final bytes = File('${File(session).parent.path}/RAW/G0001-A0001.mat').lengthSync();
  final rate = n / (sw.elapsedMicroseconds * 1e-6);
  stdout.writeln(
    '${name.padRight(24)} ${(n / 1e6).toStringAsFixed(0)}M samples x2 ch ${int16 ? 'int16' : 'int32'}: '
    '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)} s = ${(rate / 1e6).toStringAsFixed(1)} MSa/s per channel '
    '(${(bytes / sw.elapsedMicroseconds).toStringAsFixed(0)} MB/s to disk)'
    '${pace > 0 ? ', paced ${(pace / 1e6).toStringAsFixed(1)} MSa/s: max backlog ${(dig.maxBacklog / pace * 1000).toStringAsFixed(0)} ms' : ''}'
    ', live frames ${mapperEvents.whereType<LiveEvent>().length}',
  );
  tmp.deleteSync(recursive: true);
}

Future<void> main() async {
  await run('max rate', fs: 15e6, n: 60000000, int16: true);
  await run('max rate', fs: 15e6, n: 60000000, int16: false);
  await run('PXI-5922 15 MSa/s 16 bit', fs: 15e6, n: 150000000, int16: true, pace: 15e6);
  await run('500 kSa/s 24 bit', fs: 5e5, n: 5000000, int16: false, pace: 5e5);
  exit(0);
}
