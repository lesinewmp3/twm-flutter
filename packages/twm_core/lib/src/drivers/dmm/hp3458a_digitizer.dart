import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';
import '../auxiliary/aux_instruments.dart';
import '../io/instrument_io.dart';

/// Virtual digitizer composed of HP/Agilent/Keysight 3458A sampling
/// multimeters (TWM "3458A Virtual Digitizer", TPQA "LF-Setup DMMs").
///
/// Command sequences follow TPQA `SetupDMM`/`SamplingDMM` (INRIM) and the
/// 3458A manual: PRESET DIG; FUNC DCV,<rng>; TARM HOLD; TIMER/APER; MEM FIFO;
/// MFORMAT/OFORMAT SINT|DINT; TRIG ...; DELAY -1; EXTOUT APER,NEG; TBUFF ON;
/// then NRDGS n,EXT; TARM SGL on slaves and NRDGS n,TIMER; TARM SGL on master.
/// Samples are read as big endian integers and scaled by ISCALE?.
///
/// NOT VERIFIED ON REAL INSTRUMENTS (developed without hardware).
class Hp3458aDigitizer extends VirtualDigitizer {
  Hp3458aDigitizer(super.config);

  final List<InstrumentIo> _io = [];
  AwgDriver? _awg;
  CounterDriver? _counter;
  bool _open = false;

  double _ts = 1e-4;
  int _n = 0;
  double _aper = 1e-6;
  TriggerConfig _trigger = TriggerConfig();
  List<double> _ranges = [];
  bool _sint = true;
  List<double> _iscale = [];
  List<double> _temps = [];
  List<double> _timeShifts = [];

  int _pos = 0;
  bool _abort = false;
  bool _armed = false;

  Hp3458aConfig get _c => config.hp3458a;

  @override
  bool get isOpen => _open;

  /// Reading memory limits (readings, SINT/DINT) of the 3458A.
  int get _memLimit => switch (_c.memory) {
    Dmm3458Memory.standard => _sint ? 10240 : 5120,
    Dmm3458Memory.option001 => _sint ? 75000 : 37500,
    Dmm3458Memory.memoryOff => 16000000,
  };

  bool get _streaming => _c.streaming || _c.memory == Dmm3458Memory.memoryOff;

  @override
  Future<void> initialize({bool reset = false}) async {
    if (_open) await close(resetToPreset: false);
    try {
      channelIdns = [];
      for (var i = 0; i < _c.channels.length; i++) {
        final ch = _c.channels[i];
        if (ch.isF8588) {
          throw DigitizerException(
            'Fluke 8588A digitizing is not supported by this port yet '
            '(channel #${i + 1}): its command set could not be verified without the instrument.',
          );
        }
        final io = await InstrumentIoFactory.open(ch.visa, timeout: 10);
        _io.add(io);
        if (reset) {
          await io.write('RESET');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        await io.write('END ALWAYS');
        final id = await io.query('ID?');
        if (!id.contains('3458')) {
          throw DigitizerException('${ch.visa}: not a 3458A (ID? returned "$id")');
        }
        channelIdns.add(await _identify(io, i));
      }
      final ids = channelIdns.toSet();
      if (ids.length != channelIdns.length) {
        throw DigitizerException(
          'Duplicate channel identifiers: ${channelIdns.join(', ')}. '
          'Use "Sequential" descriptor mode or store serial numbers in CALSTR.',
        );
      }
      auxIdns = [];
      if (_c.sync == Dmm3458Sync.masterSlaveAwg || _c.sync == Dmm3458Sync.allAwg) {
        _awg = AwgDriver(_c.awgType, _c.awgVisa);
        await _awg!.open();
        auxIdns.add(_awg!.idn);
      }
      if (_c.sync == Dmm3458Sync.allTimer && _c.counterType != CounterType.none) {
        _counter = CounterDriver(_c.counterType, _c.counterVisa);
        await _counter!.open();
        auxIdns.add(_counter!.idn);
      }
      _ranges = [for (final c in _c.channels) c.range];
      _open = true;
    } catch (_) {
      await _closeIo();
      rethrow;
    }
  }

  static final _snRe = RegExp(r'\b([A-Z]{2}\d{8}|\d{10}|\d{4}A\d{5})\b');

  Future<String> _identify(InstrumentIo io, int i) async {
    if (_c.idnMode == Dmm3458IdnMode.sequential) return 'HP3458A, channel ${i + 1}';
    String cal = '';
    try {
      cal = await io.query('CALSTR?');
    } catch (_) {}
    final m = _snRe.firstMatch(cal.toUpperCase());
    if (m != null) return 'HP3458A, sn. ${m.group(1)}';
    if (_c.idnMode == Dmm3458IdnMode.calibrationString) {
      throw DigitizerException('${io.resource}: no serial number found in CALSTR ("$cal")');
    }
    return 'HP3458A, channel ${i + 1}';
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) {
    final ds = _c.mode != Dmm3458Mode.dcv;
    return DigitizerCapabilities(
      maxSamplesCount: _memLimit,
      maxFs: ds ? 50000 : 100000,
      minFs: 0.01,
      tsStep: 100e-9,
      stepMode: SampleRateStepMode.constPeriod,
      aperMin: ds ? null : 500e-9,
      aperMax: ds ? null : 1.0,
      channelsCount: _c.channels.length,
      allowsStreaming: true,
      streamingOn: _streaming,
      hasLevelTrig: true,
      hasExtTrig: _c.sync != Dmm3458Sync.masterSlaveAwg && _c.sync != Dmm3458Sync.allAwg,
      hasAperture: !ds && _c.apertureMode == Dmm3458ApertureMode.manual,
      hasRanges: true,
      hasTemperature: true,
      hasSelfCal: true,
      ranges: const [0.1, 1, 10, 100, 1000],
    );
  }

  /// Minimal sampling period for the aperture (guide 3.4.1.4: reserve
  /// 23 us above 100 us aperture, 10 us below).
  static double minPeriod(double aper) => aper + (aper > 100e-6 ? 23e-6 : 10e-6);

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    if (!_open) throw DigitizerException('3458A digitizer not initialized.');
    _ts = (1 / fs / 100e-9).round() * 100e-9;
    _n = samplesCount;
    _trigger = trigger;
    final ds = _c.mode != Dmm3458Mode.dcv;
    _aper = ds ? 2e-9 : aperture;
    if (!ds && _ts < minPeriod(_aper)) {
      throw DigitizerException(
        'Sampling period ${_ts * 1e6} us too short for aperture ${_aper * 1e6} us '
        '(min ${(minPeriod(_aper) * 1e6).toStringAsFixed(1)} us).',
      );
    }
    _sint = switch (_c.format) {
      Dmm3458Format.sint => true,
      Dmm3458Format.dint => false,
      Dmm3458Format.auto => ds || _aper <= 1.4e-6,
    };
    if (_n > _memLimit) {
      throw DigitizerException(
        'Samples count $_n exceeds 3458A memory ($_memLimit readings); '
        'enable streaming mode or Option 001 memory.',
      );
    }
    if (ranges.length == _io.length) _ranges = ranges;
    final fmt = _sint ? 'SINT' : 'DINT';
    final mem = _streaming ? 'OFF' : 'FIFO';
    _iscale = [];
    for (var i = 0; i < _io.length; i++) {
      final io = _io[i];
      final master = i == 0;
      final func = switch (_c.mode) {
        Dmm3458Mode.dcv => 'DCV',
        Dmm3458Mode.dsdc => 'DSDC',
        Dmm3458Mode.dsac => 'DSAC',
      };
      await io.write('PRESET DIG;FUNC $func,${_ranges[i]}');
      await io.write('TARM HOLD');
      if (ds) {
        await io.write('SWEEP ${_fmt(_ts)},$_n');
      } else {
        await io.write('TIMER ${_fmt(_ts)};APER ${_fmt(_aper)}');
      }
      await io.write('MEM $mem;MFORMAT $fmt;OFORMAT $fmt;${_trigCmd(master)};DELAY -1;EXTOUT APER,NEG;TBUFF ON');
      await io.write(_c.disableDisplay ? 'DISP OFF' : 'DISP ON');
      _iscale.add(await io.queryNumber('ISCALE?'));
      await _checkError(io);
    }
    await _awg?.setup(fs);
  }

  static String _fmt(double v) => v.toStringAsExponential(7);

  String _trigCmd(bool master) {
    final awg = _c.sync == Dmm3458Sync.masterSlaveAwg || _c.sync == Dmm3458Sync.allAwg;
    if (!master && _c.sync != Dmm3458Sync.allTimer && _c.sync != Dmm3458Sync.allAwg) return 'TRIG EXT';
    if (awg) return 'TRIG AUTO';
    return switch (_trigger.source) {
      TriggerSource.immediate => 'TRIG AUTO',
      TriggerSource.external => 'TRIG EXT',
      TriggerSource.level =>
        'TRIG LEVEL;SLOPE ${_trigger.slope == TriggerSlope.positive ? 'POS' : 'NEG'};'
            'LEVEL ${_fmt(_trigger.level)},${_trigger.coupling == TriggerCoupling.dc ? 'DC' : 'AC'}',
    };
  }

  /// Sample event of the channel (NRDGS n,<event>).
  String _sampleEvent(bool master) => switch (_c.sync) {
    Dmm3458Sync.masterSlaveTimer => master ? 'TIMER' : 'EXT',
    Dmm3458Sync.masterSlaveAwg => 'EXT',
    Dmm3458Sync.allAwg => 'EXT',
    Dmm3458Sync.allTimer => 'TIMER',
  };

  Future<void> _checkError(InstrumentIo io) async {
    final e = await io.query('ERRSTR?');
    if (!e.startsWith('0') && !e.startsWith('+0')) throw DigitizerException('${io.resource}: $e');
  }

  @override
  Future<void> initiate() async {
    _pos = 0;
    _abort = false;
    if (_c.measureTemperature) {
      _temps = [for (final io in _io) await io.queryNumber('TEMP?')];
    }
    final ds = _c.mode != Dmm3458Mode.dcv;
    // slaves first, master last (master starts the sampling)
    for (var i = _io.length - 1; i >= 0; i--) {
      final arm = ds ? 'TARM SGL' : 'NRDGS $_n,${_sampleEvent(i == 0)};TARM SGL';
      await _io[i].write(arm);
    }
    await _awg?.start();
    if (_counter != null && _io.length > 1) {
      _timeShifts = [0, await _counter!.timeInterval()];
    } else {
      _timeShifts = List.filled(_io.length, 0);
    }
    _armed = true;
  }

  @override
  Future<FetchResult> fetch() async {
    if (!_armed) throw DigitizerException('Digitizer not armed.');
    if (_abort) {
      return FetchResult(
        done: true,
        status: DigitizerStatus(done: true, fetched: _pos, total: _n, message: 'aborted'),
      );
    }
    final bps = _sint ? 2 : 4;
    final chunk = math.min(_n - _pos, 20000);
    final ch = _io.length;
    final out = Int32List(chunk * ch);
    final overload = <int>{};
    for (var c = 0; c < ch; c++) {
      final io = _io[c];
      io.timeout = 10 + chunk * _ts * 1.5;
      final b = await io.readExactly(chunk * bps);
      final bd = ByteData.sublistView(b);
      for (var i = 0; i < chunk; i++) {
        final v = _sint ? bd.getInt16(i * bps, Endian.big) : bd.getInt32(i * bps, Endian.big);
        if (_sint ? (v >= 32767 || v <= -32768) : (v >= 2147483647 || v <= -2147483648)) overload.add(c + 1);
        out[i * ch + c] = v;
      }
    }
    if (overload.isNotEmpty && !config.ignoreOverload) {
      throw DigitizerException('Overload of channel(s) ${overload.join(', ')} - check ranges.');
    }
    final pk = DataPacket(out, ch, _pos, isInt16: _sint);
    _pos += chunk;
    final done = _pos >= _n;
    return FetchResult(
      packet: pk,
      aux: AuxData(
        gains: _iscale,
        offsets: List.filled(ch, 0),
        timestamps: _timeShifts,
        increment: _ts,
        temperatures: _temps,
      ),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  @override
  Future<void> abort() async {
    _abort = true;
    for (final io in _io) {
      try {
        await io.clear();
      } catch (_) {}
    }
  }

  @override
  Future<void> cleanup() async {
    _armed = false;
    await _awg?.stop();
    for (final io in _io) {
      try {
        await io.write('TARM HOLD');
      } catch (_) {}
    }
  }

  Future<void> _closeIo() async {
    for (final io in _io) {
      try {
        await io.close();
      } catch (_) {}
    }
    _io.clear();
    await _awg?.close();
    await _counter?.close();
    _awg = null;
    _counter = null;
  }

  @override
  Future<void> close({bool resetToPreset = true}) async {
    for (final io in _io) {
      try {
        if (resetToPreset) await io.write('PRESET NORM');
        await io.write('DISP ON');
        await io.local();
      } catch (_) {}
    }
    await _closeIo();
    _open = false;
  }

  @override
  Future<void> selfCalibrate() async {
    if (!_open) await initialize();
    for (final io in _io) {
      io.timeout = 600;
      await io.write('ACAL DCV');
    }
    for (final io in _io) {
      await _checkError(io);
      io.timeout = 10;
    }
  }

  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: _n,
    channelsCount: _c.channels.length,
    fs: 1 / _ts,
    ranges: _ranges,
    trigger: _trigger,
    aperture: _aper,
    streaming: _streaming,
    isInt16: _sint,
    bitResolution: _sint ? 16 : 24,
    deviceAttributes: [
      DeviceAttribute('sampling mode', [_c.mode.name.toUpperCase()]),
      DeviceAttribute('synchronization mode', [_c.sync.label]),
    ],
  );

  @override
  String info() {
    final sb = StringBuffer(
      '${_c.channels.length} x 3458A, ${_c.mode.name.toUpperCase()} mode, '
      '${_streaming ? 'streaming' : 'memory'}.\n',
    );
    switch (_c.sync) {
      case Dmm3458Sync.masterSlaveTimer:
        sb.writeln('Connect MASTER (#1) EXT OUT to EXT TRIG of all slaves.');
      case Dmm3458Sync.masterSlaveAwg:
        sb.writeln('Connect AWG output to MASTER EXT TRIG, MASTER EXT OUT to slaves EXT TRIG.');
      case Dmm3458Sync.allAwg:
        sb.writeln('Connect AWG output to EXT TRIG of all DMMs.');
      case Dmm3458Sync.allTimer:
        sb.writeln('All DMMs clocked by internal TIMER (locked references), counter between EXT OUTs.');
    }
    sb.write('Driver not verified on real instruments.');
    return sb.toString();
  }
}
