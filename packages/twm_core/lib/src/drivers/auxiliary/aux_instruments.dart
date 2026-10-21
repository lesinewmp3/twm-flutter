import 'package:twm_model/twm_model.dart';

import '../io/instrument_io.dart';

/// Arbitrary waveform generator used as sampling clock source for DMMs
/// (TWM drivers/AWG). Generates TTL pulse train at the sampling rate.
class AwgDriver {
  final AwgType type;
  final String visa;
  InstrumentIo? _io;
  String idn = '';

  AwgDriver(this.type, this.visa);

  bool get isDummy => type == AwgType.dummy;

  Future<void> open() async {
    if (isDummy) {
      idn = 'dummy AWG (external sample clock)';
      return;
    }
    if (type == AwgType.cmiClockDivider || type == AwgType.cmiSyncV3) {
      throw InstrumentException(
        '${type.name}: protocol of this CMI device is not public - use AWG type "dummy" '
        'and configure the device manually.',
      );
    }
    _io = await InstrumentIoFactory.open(visa);
    idn = await _io!.query('*IDN?');
  }

  /// Prepares TTL pulse train (falling edge active, 3458A EXT TRIG).
  Future<void> setup(double fs) async {
    final io = _io;
    if (io == null) return;
    final f = fs.toStringAsPrecision(12);
    switch (type) {
      case AwgType.tektronixAfg3000:
        await io.write('OUTP1 OFF;:SOUR1:FUNC SQU;:SOUR1:FREQ $f;:SOUR1:VOLT:HIGH 3.3;:SOUR1:VOLT:LOW 0');
      case AwgType.agilent33xxx:
      case AwgType.agilent3352x:
      case AwgType.rasHmf2500:
        await io.write('OUTP OFF;:FUNC SQU;:FREQ $f;:VOLT:HIGH 3.3;:VOLT:LOW 0;:OUTP:LOAD INF');
      default:
        break;
    }
  }

  Future<void> start() async {
    final io = _io;
    if (io == null) return;
    await io.write(type == AwgType.tektronixAfg3000 ? 'OUTP1 ON' : 'OUTP ON');
  }

  Future<void> stop() async {
    final io = _io;
    if (io == null) return;
    await io.write(type == AwgType.tektronixAfg3000 ? 'OUTP1 OFF' : 'OUTP OFF');
  }

  Future<void> close() async {
    await _io?.local();
    await _io?.close();
    _io = null;
  }
}

/// Interval counter / frequency counter (TWM drivers/Counter: Picotest
/// U6200 series, SCPI compatible with Agilent 53131A).
class CounterDriver {
  final CounterType type;
  final String visa;
  InstrumentIo? _io;
  String idn = '';

  CounterDriver(this.type, this.visa);

  Future<void> open() async {
    if (type == CounterType.none) return;
    _io = await InstrumentIoFactory.open(visa, timeout: 20);
    idn = await _io!.query('*IDN?');
  }

  /// Time interval channel 1 -> channel 2 [s] (DMM EXT OUT delay).
  Future<double> timeInterval() async {
    final io = _io;
    if (io == null) return 0;
    await io.write(':CONF:TINT (@1),(@2)');
    return io.queryNumber(':READ?');
  }

  /// Frequency on channel [ch] [Hz] (sampling assistant measurement).
  Future<double> frequency({int ch = 1}) async {
    final io = _io;
    if (io == null) throw InstrumentException('No counter configured');
    await io.write(':CONF:FREQ (@$ch)');
    return io.queryNumber(':READ?');
  }

  Future<void> close() async {
    await _io?.local();
    await _io?.close();
    _io = null;
  }
}
