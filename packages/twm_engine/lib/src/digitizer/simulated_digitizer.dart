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
    channelIdns = [for (var i = 0; i < _cfg.channels.length; i++) 'Simulated ADC, channel ${i + 1}'];
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
      throw DigitizerException('Sampling rate ${Info.formatNumber(fs)} Sa/s out of range (max ${Info.formatNumber(_cfg.maxFs)}).');
    }
    _fs = fs;
    _n = samplesCount;
    _trigger = trigger;
    _aperture = aperture;
    _ranges = ranges.length == _cfg.channels.length ? ranges : [for (final c in _cfg.channels) c.range];
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
      return FetchResult(
        done: true,
        status: DigitizerStatus(done: true, fetched: _pos, total: _n, message: 'aborted'),
      );
    }
    // how many samples "exist" by now
    final rt = _cfg.realtimeFactor;
    final avail = rt <= 0 ? _n : math.min(_n, (_armClock.elapsedMicroseconds * 1e-6 * _fs / rt).floor());
    var count = math.min(avail - _pos, 200000);
    if (count <= 0) {
      // wait until the rest of the record (or the next block) exists
      final need = math.min(_n - _pos, 200000);
      final us = ((_pos + need) / _fs * rt * 1e6 - _armClock.elapsedMicroseconds).ceil();
      // at most 10 ms: data flow like a real streaming digitizer (smooth live view)
      await Future<void>.delayed(Duration(microseconds: us.clamp(100, 10000)));
      return FetchResult(
        status: DigitizerStatus(sampling: true, fetched: _pos, total: _n),
      );
    }
    final data = Int32List(count * ch);
    final gains = _gains;
    final maxCode = (1 << (_cfg.bits - 1)) - 1;
    final ts = 1 / _fs;
    final v = Float64List(count);
    for (var c = 0; c < ch; c++) {
      final cc = _cfg.channels[c];
      v.fillRange(0, count, cc.dc);
      if (_cfg.jitterRms > 0 || cc.event != null) {
        _harmonicsExact(v, cc, ts);
      } else {
        for (final h in cc.harmonics) {
          _addTone(v, h, cc.timeShift, ts);
        }
      }
      if (cc.noiseRms > 0) {
        for (var i = 0; i < count; i++) {
          v[i] += _gauss() * cc.noiseRms;
        }
      }
      final g = gains[c];
      for (var i = 0; i < count; i++) {
        var code = (v[i] / g).round();
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
      aux: AuxData(gains: gains, offsets: List.filled(ch, 0), timestamps: List.filled(ch, _t0), increment: ts),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  static double _frac(double x) => x - x.floorToDouble();

  /// Adds A sin(2 pi f t + ph) for the samples of this block. The phase is
  /// kept as fractional cycles: f*t0 (time since driver start) is reduced
  /// separately from the channel delay, so neither a long run time nor a high
  /// frequency costs precision, and the channels share the same f*t0 term.
  /// Samples are generated by a rotating phasor, re-anchored to the exact
  /// phase every 64 samples (error ~1e-14, about 10x faster than sin()).
  void _addTone(Float64List v, SimHarmonic h, double shift, double ts) {
    final f = h.freq, a = h.amp;
    if (a == 0) return;
    final cyc0 = _frac(f * _t0) + _frac(f * shift) + h.phase / (2 * math.pi);
    final dc = f * ts; // cycles per sample
    final wr = math.cos(2 * math.pi * dc), wi = math.sin(2 * math.pi * dc);
    final n = v.length;
    for (var i0 = 0; i0 < n; i0 += 64) {
      final th = 2 * math.pi * _frac(cyc0 + _frac(dc * (_pos + i0)));
      var zr = math.cos(th), zi = math.sin(th);
      final e = math.min(n, i0 + 64);
      for (var i = i0; i < e; i++) {
        v[i] += a * zi;
        final nr = zr * wr - zi * wi;
        zi = zr * wi + zi * wr;
        zr = nr;
      }
    }
  }

  /// Exact per sample evaluation: sampling jitter, events (sag/interruption
  /// with a phase jump after it, the time of the event is relative to the
  /// record start).
  void _harmonicsExact(Float64List v, SimChannelConfig cc, double ts) {
    final ev = cc.event;
    for (var i = 0; i < v.length; i++) {
      final dt = _cfg.jitterRms > 0 ? _gauss() * _cfg.jitterRms : 0.0;
      final tr = (_pos + i) * ts; // time in the record
      var k = 1.0, jump = 0.0;
      if (ev != null) {
        if (tr >= ev.start && tr < ev.start + ev.duration) k = ev.level;
        if (tr >= ev.start + ev.duration) jump = ev.phaseJump;
      }
      for (final h in cc.harmonics) {
        final cyc = _frac(h.freq * _t0) + _frac(h.freq * cc.timeShift) + _frac(h.freq * ts * (_pos + i)) + h.freq * dt;
        // harmonics follow the fundamental phase jump (h x jump)
        v[i] += k * h.amp * math.sin(2 * math.pi * cyc + h.phase + jump * h.freq / cc.harmonics.first.freq);
      }
    }
  }

  double? _spare;

  /// Normal random number (Box-Muller, both outputs used).
  double _gauss() {
    final s = _spare;
    if (s != null) {
      _spare = null;
      return s;
    }
    final u1 = 1 - _rnd.nextDouble();
    final u2 = _rnd.nextDouble();
    final r = math.sqrt(-2 * math.log(u1));
    _spare = r * math.sin(2 * math.pi * u2);
    return r * math.cos(2 * math.pi * u2);
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
  Future<void> selfCalibrate() async => Future<void>.delayed(const Duration(milliseconds: 500));

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
    fullScaleCode: (1 << (_cfg.bits - 1)) - 1,
  );

  @override
  String info() {
    final sb = StringBuffer(
      'Simulated digitizer, ${_cfg.bits} bit, '
      '${_cfg.channels.length} channel(s).\n',
    );
    for (var i = 0; i < _cfg.channels.length; i++) {
      final c = _cfg.channels[i];
      sb.writeln(
        '#${i + 1} ${c.name}: range ${c.range} V, '
        '${c.harmonics.length} harmonic(s), noise ${c.noiseRms} V rms',
      );
    }
    return sb.toString();
  }
}
