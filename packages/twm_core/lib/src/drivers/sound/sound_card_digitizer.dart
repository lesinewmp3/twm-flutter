import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';
import 'sound_capture.dart';

/// Sound card digitizer (TWM "dsdll" driver: DirectSound). Low accuracy,
/// AC coupled - for tests, phase, THD and spectrum measurements.
class SoundCardDigitizer extends VirtualDigitizer {
  SoundCardDigitizer(super.config);

  static const rates = <double>[8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 192000];

  bool _open = false;
  double _fs = 48000;
  int _n = 0;
  TriggerConfig _trigger = TriggerConfig();
  Isolate? _iso;
  ReceivePort? _port;
  final _queue = Queue<Int32List>();
  bool _done = false;
  String? _error;
  int _pos = 0;
  bool _abort = false;
  final _clock = Stopwatch();
  double _t0 = 0;

  SoundCardConfig get _c => config.soundCard;

  @override
  bool get isOpen => _open;

  @override
  Future<List<String>> enumerateDevices() async => soundDevices();

  @override
  Future<void> initialize({bool reset = false}) async {
    final devs = soundDevices();
    if (devs.isEmpty) throw DigitizerException('Sound capture is not supported on this platform.');
    channelIdns = [for (var i = 1; i <= _c.channels; i++) 'Sound card ${_c.device}, channel $i'];
    auxIdns = [];
    if (!_clock.isRunning) _clock.start();
    _open = true;
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) => DigitizerCapabilities(
    maxSamplesCount: 100000000,
    maxFs: 192000,
    minFs: 8000,
    channelsCount: _c.channels,
    fixedRates: rates,
    ranges: [_c.range],
  );

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    if (!rates.contains(fs)) throw DigitizerException('Sound card supports only rates ${rates.join(', ')} Sa/s.');
    if (trigger.source != TriggerSource.immediate)
      throw DigitizerException('Sound card supports immediate trigger only.');
    _fs = fs;
    _n = samplesCount;
    _trigger = trigger;
  }

  @override
  Future<void> initiate() async {
    _queue.clear();
    _done = false;
    _error = null;
    _pos = 0;
    _abort = false;
    _t0 = _clock.elapsedMicroseconds * 1e-6;
    final port = ReceivePort();
    _port = port;
    port.listen((m) {
      if (m is TransferableTypedData) {
        _queue.add(m.materialize().asInt32List());
      } else if (m is String) {
        _error = m;
        _done = true;
      } else if (m == null) {
        _done = true;
      }
    });
    _iso = await Isolate.spawn(
      captureMain,
      CaptureRequest(_c.device, _c.channels, _fs.round(), _c.bits == 16 ? 16 : 32, _n, port.sendPort),
    );
  }

  double get _gain => _c.range / (_c.bits == 16 ? 32768.0 : 2147483648.0);

  @override
  Future<FetchResult> fetch() async {
    if (_error != null) throw DigitizerException(_error!);
    if (_abort) {
      return FetchResult(
        done: true,
        status: DigitizerStatus(done: true, fetched: _pos, total: _n, message: 'aborted'),
      );
    }
    if (_queue.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (_error != null) throw DigitizerException(_error!);
      final finished = _done && _queue.isEmpty;
      if (finished && _pos < _n) throw DigitizerException('Sound capture ended prematurely ($_pos/$_n samples).');
      return FetchResult(
        status: DigitizerStatus(sampling: true, fetched: _pos, total: _n),
      );
    }
    // merge queued blocks
    final blocks = <Int32List>[];
    while (_queue.isNotEmpty) {
      blocks.add(_queue.removeFirst());
    }
    final len = blocks.fold<int>(0, (s, b) => s + b.length);
    final data = Int32List(len);
    var o = 0;
    for (final b in blocks) {
      data.setAll(o, b);
      o += b.length;
    }
    final pk = DataPacket(data, _c.channels, _pos, isInt16: _c.bits == 16);
    _pos += pk.count;
    final done = _pos >= _n;
    return FetchResult(
      packet: pk,
      aux: AuxData(
        gains: List.filled(_c.channels, _gain),
        offsets: List.filled(_c.channels, 0),
        timestamps: List.filled(_c.channels, _t0),
        increment: 1 / _fs,
      ),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  @override
  Future<void> abort() async {
    _abort = true;
    _iso?.kill(priority: Isolate.immediate);
  }

  @override
  Future<void> cleanup() async {
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _port?.close();
    _port = null;
  }

  @override
  Future<void> close({bool resetToPreset = true}) async {
    await cleanup();
    _open = false;
  }

  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: _n,
    channelsCount: _c.channels,
    fs: _fs,
    ranges: List.filled(_c.channels, _c.range),
    trigger: _trigger,
    isInt16: _c.bits == 16,
    bitResolution: _c.bits,
    deviceAttributes: [
      DeviceAttribute('capture device', [_c.device]),
    ],
  );

  @override
  String info() =>
      'Sound card "${_c.device}", ${_c.channels} channel(s), ${_c.bits} bit. '
      'AC coupled input, uncalibrated - use digitizer corrections for gain.';
}
