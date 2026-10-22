import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';
import '../auxiliary/aux_instruments.dart';
import '../io/instrument_io.dart';
import '../io/visa_io.dart';

/// Virtual digitizer composed of HP/Agilent/Keysight 3458A sampling
/// multimeters (TWM "3458A Virtual Digitizer", TPQA "LF-Setup DMMs").
///
/// Command sequences follow TPQA `SetupDMM`/`SamplingDMM` (INRIM) and the
/// 3458A manual: PRESET DIG; FUNC DCV,<rng>; TARM HOLD; TIMER/APER; MEM FIFO;
/// MFORMAT/OFORMAT SINT|DINT; TRIG ...; DELAY -1; EXTOUT APER,NEG; TBUFF ON;
/// then NRDGS n,EXT; TARM SGL on slaves and NRDGS n,TIMER; TARM SGL on master.
/// As TWM ("3458A Digitizing Low Levels"): the memory is cleared and the
/// trigger buffer disabled before arming (TBUFF OFF;MEM FIFO, a trigger coming
/// too fast is an error, not a silently delayed sample) and the binary samples
/// are transferred with END OFF (no EOI after each reading). In the streaming
/// mode (no reading memory) all DMMs are read in parallel, each on its own GPIB
/// controller. Samples are read as big endian integers and scaled by ISCALE?.
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
  List<VisaStreamReader> _readers = [];

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
    if (_streaming && _c.channels.length > 1) {
      // TWM "3458A Check Addresses": streaming needs one controller per DMM
      final boards = [
        for (final c in _c.channels)
          if (RegExp(r'^GPIB(\d*)::', caseSensitive: false).firstMatch(c.visa.trim()) case final m?)
            m.group(1)!.isEmpty ? '0' : m.group(1)!,
      ];
      if (boards.toSet().length != boards.length) {
        throw DigitizerException(
          'Streaming mode needs each 3458A on its own GPIB controller '
          '(${[for (final c in _c.channels) c.visa].join(', ')}); use the memory mode with a shared bus.',
        );
      }
    }
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
        'Sampling period ${_us(_ts)} us too short for aperture ${_us(_aper)} us '
        '(min ${_us(minPeriod(_aper))} us).',
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
    // memory cleared (MEM OFF), then FIFO except for streaming
    final mem = _streaming ? 'OFF' : 'OFF;MEM FIFO';
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

  /// [s] in microseconds for messages: 14.3, not 14.299999999999999.
  static String _us(double s) => (s * 1e6).toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');

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
    _stopReaders(); // (left by a record ended with an error)
    if (_c.measureTemperature) {
      _temps = [for (final io in _io) await io.queryNumber('TEMP?')];
    }
    final ds = _c.mode != Dmm3458Mode.dcv;
    // empty memory, trigger buffer off, binary readings without EOI (TWM)
    final pre = _streaming ? 'TBUFF OFF;MEM OFF;END OFF' : 'TBUFF OFF;MEM FIFO;END OFF';
    final arm = [
      for (var i = 0; i < _io.length; i++)
        ds ? '$pre;TARM SGL' : '$pre;NRDGS $_n,${_sampleEvent(i == 0)};TARM SGL',
    ];
    if (_streaming && _io.every((io) => io is VisaIo)) {
      // streaming: the readings are not stored, all DMMs are read at once and
      // each reader arms its DMM and reads right after it (TWM processes)
      final bps = _sint ? 2 : 4;
      for (final io in _io) {
        io.timeout = _readTimeout;
        _readers.add(await VisaStreamReader.start(io as VisaIo, total: _n * bps, block: _chunk * bps));
      }
      // slaves first, master last (master starts the sampling)
      for (var i = _io.length - 1; i >= 0; i--) {
        await _readers[i].go(arm[i]);
      }
    } else {
      for (var i = _io.length - 1; i >= 0; i--) {
        await _io[i].write(arm[i]);
      }
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
    final ch = _io.length;
    final blocks = <Uint8List>[];
    try {
      for (var c = 0; c < ch; c++) {
        if (_readers.isNotEmpty) {
          blocks.add(await _readers[c].next());
        } else {
          _io[c].timeout = _readTimeout;
          blocks.add(await _io[c].readExactly(math.min(_n - _pos, _chunk) * bps));
        }
      }
    } catch (_) {
      // a read ended by the device clear of abort()
      if (_abort) {
        return FetchResult(
          done: true,
          status: DigitizerStatus(done: true, fetched: _pos, total: _n, message: 'aborted'),
        );
      }
      rethrow;
    }
    final chunk = blocks.first.length ~/ bps;
    final out = Int32List(chunk * ch);
    final overload = <int>{};
    for (var c = 0; c < ch; c++) {
      final bd = ByteData.sublistView(blocks[c]);
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

  /// Readings transferred at once: 20000 from the memory, 0.1 s of streaming.
  int get _chunk => _streaming ? (0.1 / _ts).round().clamp(100, 20000) : 20000;

  /// Read timeout of one chunk [s].
  double get _readTimeout => 10 + _chunk * _ts * 1.5;

  @override
  Future<void> abort() async {
    _abort = true;
    for (final io in _io) {
      try {
        await io.clear();
      } catch (_) {}
    }
  }

  void _stopReaders() {
    for (final r in _readers) {
      r.stop();
    }
    _readers = [];
  }

  @override
  Future<void> cleanup() async {
    _armed = false;
    _stopReaders();
    await _awg?.stop();
    for (final io in _io) {
      try {
        await io.write('TARM HOLD;END ALWAYS');
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
