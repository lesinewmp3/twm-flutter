import 'dart:async';
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';
import '../io/instrument_io.dart';

/// Keysight Infiniium DSO (90000/S series) used as digitizer (TWM "Agilent
/// DSO 90000" driver, tested in TWM only with DSOS604A). SCPI over VISA:
/// :SINGle acquisition, :ADER? polling and :WAVeform:DATA? WORD transfer.
///
/// NOT VERIFIED ON REAL INSTRUMENTS (developed without hardware).
class KeysightDsoDigitizer extends VirtualDigitizer {
  KeysightDsoDigitizer(super.config);

  InstrumentIo? _io;
  double _fs = 1e6;
  int _n = 0;
  TriggerConfig _trigger = TriggerConfig();
  List<double> _ranges = [];
  bool _armed = false;
  bool _abort = false;
  final _sw = Stopwatch();

  DsoConfig get _c => config.dso;

  @override
  bool get isOpen => _io != null;

  @override
  Future<void> initialize({bool reset = false}) async {
    await close(resetToPreset: false);
    final io = await InstrumentIoFactory.open(_c.visa, timeout: 10);
    _io = io;
    if (reset) {
      await io.write('*RST');
      await io.query('*OPC?');
    }
    final idn = await io.query('*IDN?');
    if (!idn.toUpperCase().contains('KEYSIGHT') && !idn.toUpperCase().contains('AGILENT')) {
      await close(resetToPreset: false);
      throw DigitizerException('${_c.visa}: not a Keysight/Agilent DSO ("$idn")');
    }
    final parts = idn.split(',');
    final model = parts.length > 1 ? parts[1].trim() : 'DSO';
    final sn = parts.length > 2 ? parts[2].trim() : '';
    channelIdns = [for (final c in _c.channels) '$model $sn, channel ${c.channelId}'];
    auxIdns = [];
    _ranges = [for (final c in _c.channels) c.range];
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) => DigitizerCapabilities(
    maxSamplesCount: 100000000,
    maxFs: 20e9,
    minFs: 10,
    channelsCount: _c.channels.length,
    hasLevelTrig: true,
    hasExtTrig: true,
    hasRanges: true,
  );

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    final io = _io;
    if (io == null) throw DigitizerException('DSO not initialized.');
    _n = samplesCount;
    _trigger = trigger;
    if (ranges.length == _c.channels.length) _ranges = ranges;
    await io.write(
      ':STOP;:ACQuire:MODE RTIMe;:ACQuire:SRATe:ANALog ${fs.toStringAsExponential(6)};'
      ':ACQuire:POINts:ANALog $_n',
    );
    await io.write(':ACQuire:HRESolution ${_c.bitResolution == 'Auto' ? 'AUTO' : 'BITS${_c.bitResolution}'}');
    await io.write(_c.bwLimit > 0 ? ':ACQuire:BANDwidth ${_c.bwLimit}' : ':ACQuire:BANDwidth MAX');
    for (var i = 0; i < _c.channels.length; i++) {
      final ch = _c.channels[i];
      final inp = switch (ch.coupling) {
        DsoCoupling.dc1M => 'DC',
        DsoCoupling.ac1M => 'AC',
        DsoCoupling.dc50 => 'DC50',
      };
      // full screen range = 2 * peak value with some headroom
      await io.write(
        ':CHANnel${ch.channelId}:DISPlay ON;:CHANnel${ch.channelId}:INPut $inp;'
        ':CHANnel${ch.channelId}:RANGe ${(2.2 * _ranges[i]).toStringAsExponential(4)};'
        ':CHANnel${ch.channelId}:OFFSet ${ch.offset}',
      );
    }
    final first = _c.channels.first.channelId;
    switch (trigger.source) {
      case TriggerSource.immediate:
        await io.write(':TRIGger:SWEep AUTO');
      case TriggerSource.level:
      case TriggerSource.external:
        final src = trigger.source == TriggerSource.external ? 'AUX' : 'CHANnel$first';
        await io.write(
          ':TRIGger:SWEep TRIGgered;:TRIGger:MODE EDGE;:TRIGger:EDGE:SOURce $src;'
          ':TRIGger:EDGE:SLOPe ${trigger.slope == TriggerSlope.positive ? 'POSitive' : 'NEGative'};'
          ':TRIGger:LEVel $src,${trigger.level};'
          ':TRIGger:HYSTeresis ${_c.noiseReject == 'ON' ? 'NREJect' : 'NORMal'}',
        );
    }
    await io.write(':WAVeform:FORMat WORD;:WAVeform:BYTeorder LSBFirst;:WAVeform:STReaming OFF');
    _fs = await io.queryNumber(':ACQuire:SRATe:ANALog?');
    final err = await io.query(':SYSTem:ERRor?');
    if (!err.startsWith('0') && !err.startsWith('+0')) throw DigitizerException('DSO: $err');
  }

  @override
  Future<void> initiate() async {
    final io = _io!;
    _abort = false;
    await io.query(':ADER?'); // clear acquisition done register
    await io.write(':SINGle');
    _sw
      ..reset()
      ..start();
    _armed = true;
  }

  @override
  Future<FetchResult> fetch() async {
    final io = _io!;
    if (!_armed) throw DigitizerException('Digitizer not armed.');
    if (_abort)
      return FetchResult(
        done: true,
        status: DigitizerStatus(done: true, total: _n, message: 'aborted'),
      );
    final done = (await io.queryNumber(':ADER?')) != 0;
    if (!done) {
      if (_sw.elapsed.inSeconds > 60 + _n / _fs) throw DigitizerException('DSO acquisition timeout.');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return FetchResult(status: DigitizerStatus(sampling: true, total: _n));
    }
    final nch = _c.channels.length;
    final out = Int32List(_n * nch);
    final gains = <double>[];
    final offsets = <double>[];
    final stamps = <double>[];
    var inc = 1 / _fs;
    for (var i = 0; i < nch; i++) {
      final id = _c.channels[i].channelId;
      await io.write(':WAVeform:SOURce CHANnel$id');
      gains.add(await io.queryNumber(':WAVeform:YINCrement?'));
      offsets.add(await io.queryNumber(':WAVeform:YORigin?'));
      inc = await io.queryNumber(':WAVeform:XINCrement?');
      stamps.add(await io.queryNumber(':WAVeform:XORigin?'));
      io.timeout = 10 + _n * 2 / 1e6;
      await io.write(':WAVeform:DATA?');
      final b = await io.readBlock();
      io.timeout = 10;
      final bd = ByteData.sublistView(b);
      final m = b.length ~/ 2 < _n ? b.length ~/ 2 : _n;
      for (var k = 0; k < m; k++) {
        out[k * nch + i] = bd.getInt16(k * 2, Endian.little);
      }
    }
    return FetchResult(
      packet: DataPacket(out, nch, 0, isInt16: true),
      aux: AuxData(gains: gains, offsets: offsets, timestamps: stamps, increment: inc),
      done: true,
      status: DigitizerStatus(done: true, fetched: _n, total: _n),
    );
  }

  @override
  Future<void> abort() async {
    _abort = true;
    try {
      await _io?.write(':STOP');
    } catch (_) {}
  }

  @override
  Future<void> cleanup() async => _armed = false;

  @override
  Future<void> close({bool resetToPreset = true}) async {
    final io = _io;
    _io = null;
    if (io == null) return;
    try {
      await io.write(':RUN');
      await io.local();
    } catch (_) {}
    await io.close();
  }

  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: _n,
    channelsCount: _c.channels.length,
    fs: _fs,
    ranges: _ranges,
    trigger: _trigger,
    isInt16: true,
    bitResolution: _c.bitResolution == 'Auto' ? 10 : int.parse(_c.bitResolution),
  );

  @override
  String info() =>
      'Keysight DSO at ${_c.visa}, ${_c.channels.length} channel(s). Very basic driver '
      '(physical range selected by DSO). Not verified on real instruments.';
}
