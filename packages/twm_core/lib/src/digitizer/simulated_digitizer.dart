import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import 'virtual_digitizer.dart';

/// Simulated digitizer - synthesizer of composite harmonic signals with
/// noise, quantization and jitter (TWM "simulated_adc" driver). Used for
/// development and demonstrations without hardware.
class SimulatedDigitizer extends VirtualDigitizer {
  SimulatedDigitizer(super.config);

  bool _open = false;
  final _rnd = math.Random(1);
  final _clock = Stopwatch();

  double _fs = 10000;
  int _n = 0;
  TriggerConfig _trigger = TriggerConfig();
  double _aperture = 0;
  List<double> _ranges = [];

  int _pos = 0;
  double _t0 = 0;
  bool _abort = false;
  bool _armed = false;
  final _armClock = Stopwatch();

  SimulatedConfig get _cfg => config.simulated;

  @override
  bool get isOpen => _open;

  @override
  Future<void> initialize({bool reset = false}) async {
    _open = true;
    if (!_clock.isRunning) _clock.start();
    channelIdns = [
      for (var i = 0; i < _cfg.channels.length; i++)
        'Simulated ADC, channel ${i + 1}'
    ];
    auxIdns = [];
    _ranges = [for (final c in _cfg.channels) c.range];
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) => DigitizerCapabilities(
        maxSamplesCount: 100000000,
        maxFs: _cfg.maxFs,
        minFs: 1,
        fsStep: 1e-6,
        channelsCount: _cfg.channels.length,
        hasLevelTrig: false,
        hasExtTrig: false,
        hasAperture: true,
        aperMin: 0,
        aperMax: 1,
        hasRanges: true,
        ranges: const [0.1, 1, 10, 100, 1000],
      );

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    if (!_open) throw DigitizerException('Simulated digitizer not initialized.');
    if (fs <= 0 || fs > _cfg.maxFs) {
      throw DigitizerException('Sampling rate $fs Sa/s out of range (max ${_cfg.maxFs}).');
    }
    _fs = fs;
    _n = samplesCount;
    _trigger = trigger;
    _aperture = aperture;
    _ranges = ranges.length == _cfg.channels.length
        ? ranges
        : [for (final c in _cfg.channels) c.range];
  }

  double get _gainLsb => 1.0 / (1 << (_cfg.bits - 1));

  List<double> get _gains => [for (final r in _ranges) r * _gainLsb];

  @override
  Future<void> initiate() async {
    _pos = 0;
    _abort = false;
    _armed = true;
    // relative time stamp: time since driver initialization
    _t0 = _clock.elapsedMicroseconds * 1e-6;
    _armClock
      ..reset()
      ..start();
  }

  @override
  Future<FetchResult> fetch() async {
    if (!_armed) throw DigitizerException('Digitizer not armed.');
    final ch = _cfg.channels.length;
    if (_abort) {
      return FetchResult(done: true, status: DigitizerStatus(done: true, fetched: _pos, total: _n, message: 'aborted'));
    }
    // how many samples "exist" by now
    final rt = _cfg.realtimeFactor;
    final avail = rt <= 0
        ? _n
        : math.min(_n, (_armClock.elapsedMicroseconds * 1e-6 * _fs / rt).floor());
    var count = math.min(avail - _pos, 200000);
    if (count <= 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return FetchResult(status: DigitizerStatus(sampling: true, fetched: _pos, total: _n));
    }
    final data = Int32List(count * ch);
    final gains = _gains;
    final maxCode = (1 << (_cfg.bits - 1)) - 1;
    final ts = 1 / _fs;
    for (var c = 0; c < ch; c++) {
      final cc = _cfg.channels[c];
      final g = gains[c];
      final noise = cc.noiseRms;
      for (var i = 0; i < count; i++) {
        var t = _t0 + cc.timeShift + (_pos + i) * ts;
        if (_cfg.jitterRms > 0) t += _gauss() * _cfg.jitterRms;
        var v = cc.dc;
        for (final h in cc.harmonics) {
          v += h.amp * math.sin(2 * math.pi * h.freq * t + h.phase);
        }
        if (noise > 0) v += _gauss() * noise;
        var code = (v / g).round();
        if (code > maxCode) code = maxCode;
        if (code < -maxCode) code = -maxCode;
        data[i * ch + c] = code;
      }
    }
    final packet = DataPacket(data, ch, _pos, isInt16: _cfg.bits <= 16);
    _pos += count;
    final done = _pos >= _n;
    return FetchResult(
      packet: packet,
      aux: AuxData(
        gains: gains,
        offsets: List.filled(ch, 0),
        timestamps: List.filled(ch, _t0),
        increment: ts,
      ),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  double _gauss() {
    // Box-Muller
    final u1 = 1 - _rnd.nextDouble();
    final u2 = _rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  @override
  Future<void> abort() async => _abort = true;

  @override
  Future<void> cleanup() async {
    _armed = false;
    _armClock.stop();
  }

  @override
  Future<void> close({bool resetToPreset = true}) async => _open = false;

  @override
  Future<void> selfCalibrate() async =>
      Future<void>.delayed(const Duration(milliseconds: 500));

  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
        samplesCount: _n,
        channelsCount: _cfg.channels.length,
        fs: _fs,
        ranges: _ranges,
        trigger: _trigger,
        aperture: _aperture,
        isInt16: _cfg.bits <= 16,
        bitResolution: _cfg.bits,
      );

  @override
  String info() {
    final sb = StringBuffer('Simulated digitizer, ${_cfg.bits} bit, '
        '${_cfg.channels.length} channel(s).\n');
    for (var i = 0; i < _cfg.channels.length; i++) {
      final c = _cfg.channels[i];
      sb.writeln('#${i + 1} ${c.name}: range ${c.range} V, '
          '${c.harmonics.length} harmonic(s), noise ${c.noiseRms} V rms');
    }
    return sb.toString();
  }
}
