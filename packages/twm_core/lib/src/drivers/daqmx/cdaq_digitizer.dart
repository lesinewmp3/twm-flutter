import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';

typedef _CreateTaskN = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CreateTaskD = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _TaskN = Int32 Function(Pointer<Void>);
typedef _TaskD = int Function(Pointer<Void>);
typedef _AiChanN =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32, Double, Double, Int32, Pointer<Utf8>);
typedef _AiChanD = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, double, double, int, Pointer<Utf8>);
typedef _TimingN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Double, Int32, Int32, Uint64);
typedef _TimingD = int Function(Pointer<Void>, Pointer<Utf8>, double, int, int, int);
typedef _ReadN =
    Int32 Function(Pointer<Void>, Int32, Double, Uint32, Pointer<Double>, Uint32, Pointer<Int32>, Pointer<Void>);
typedef _ReadD = int Function(Pointer<Void>, int, double, int, Pointer<Double>, int, Pointer<Int32>, Pointer<Void>);
typedef _ErrN = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ErrD = int Function(Pointer<Utf8>, int);
typedef _SetStrN = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetStrD = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetDblN = Int32 Function(Pointer<Void>, Double);
typedef _SetDblD = int Function(Pointer<Void>, double);
typedef _GetU64N = Int32 Function(Pointer<Void>, Pointer<Uint64>);
typedef _GetU64D = int Function(Pointer<Void>, Pointer<Uint64>);

class DaqMx {
  static const valDefault = -1;
  static const valVolts = 10348;
  static const valRising = 10280;
  static const valContSamps = 10123;
  static const valGroupByScanNumber = 1;

  final DynamicLibrary lib;
  DaqMx(this.lib);

  late final createTask = lib.lookupFunction<_CreateTaskN, _CreateTaskD>('DAQmxCreateTask');
  late final startTask = lib.lookupFunction<_TaskN, _TaskD>('DAQmxStartTask');
  late final stopTask = lib.lookupFunction<_TaskN, _TaskD>('DAQmxStopTask');
  late final clearTask = lib.lookupFunction<_TaskN, _TaskD>('DAQmxClearTask');
  late final createAIVoltageChan = lib.lookupFunction<_AiChanN, _AiChanD>('DAQmxCreateAIVoltageChan');
  late final cfgSampClkTiming = lib.lookupFunction<_TimingN, _TimingD>('DAQmxCfgSampClkTiming');
  late final readAnalogF64 = lib.lookupFunction<_ReadN, _ReadD>('DAQmxReadAnalogF64');
  late final getExtendedErrorInfo = lib.lookupFunction<_ErrN, _ErrD>('DAQmxGetExtendedErrorInfo');
  late final setMasterTimebaseSrc = lib.lookupFunction<_SetStrN, _SetStrD>('DAQmxSetMasterTimebaseSrc');
  late final setMasterTimebaseRate = lib.lookupFunction<_SetDblN, _SetDblD>('DAQmxSetMasterTimebaseRate');
  late final getReadTotalSampPerChanAcquired = lib.lookupFunction<_GetU64N, _GetU64D>(
    'DAQmxGetReadTotalSampPerChanAcquired',
  );

  static DaqMx? _i;
  static DaqMx get instance {
    if (_i != null) return _i!;
    for (final n in Platform.isWindows ? ['nicaiu.dll'] : ['libnidaqmx.so', 'libnidaqmx.so.1']) {
      try {
        return _i = DaqMx(DynamicLibrary.open(n));
      } catch (_) {}
    }
    throw DigitizerException('NI-DAQmx library not found - install NI-DAQmx driver.');
  }

  void check(int st, String what) {
    if (st >= 0) return;
    final buf = calloc<Uint8>(2048).cast<Utf8>();
    try {
      getExtendedErrorInfo(buf, 2048);
      throw DigitizerException('DAQmx $what: ${buf.toDartString()}');
    } finally {
      calloc.free(buf);
    }
  }
}

/// cDAQ NI 9238 digitizer (TWM "cdaq" driver). The module digitizes
/// continuously in background; records are cut from the stream so that
/// relative time stamps (sample index / fs) are available, as in TWM.
///
/// NOT VERIFIED ON REAL INSTRUMENTS (developed without hardware).
class CdaqDigitizer extends VirtualDigitizer {
  CdaqDigitizer(super.config);

  Pointer<Void> _task = nullptr;
  bool _open = false;
  bool _running = false;
  int _n = 0;
  int _pos = 0;
  int _startIndex = 0;
  bool _abort = false;
  TriggerConfig _trigger = TriggerConfig();
  int _streamPos = 0; // samples read from the stream since task start

  CdaqConfig get _c => config.cdaq;
  DaqMx get _d => DaqMx.instance;
  static const range = 0.5; // NI 9238: +-0.5 V

  @override
  bool get isOpen => _open;

  @override
  Future<void> initialize({bool reset = false}) async {
    DaqMx.instance; // check library
    if (_c.channelIds.isEmpty) throw DigitizerException('No cDAQ channels selected.');
    channelIdns = [for (final i in _c.channelIds) 'NI 9238 ${_c.device}/ai$i'];
    auxIdns = [];
    _open = true;
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) => DigitizerCapabilities(
    maxSamplesCount: 1 << 30,
    maxFs: _c.fixedRate,
    minFs: _c.fixedRate,
    channelsCount: _c.channelIds.length,
    fixedRates: [_c.fixedRate],
    ranges: const [range],
  );

  Future<void> _startStream() async {
    if (_running) return;
    final p = calloc<Pointer<Void>>();
    final name = ''.toNativeUtf8();
    try {
      _d.check(_d.createTask(name, p), 'CreateTask');
      _task = p.value;
    } finally {
      calloc.free(p);
      calloc.free(name);
    }
    final phys = _c.channelIds.map((i) => '${_c.device}/ai$i').join(',').toNativeUtf8();
    final empty = ''.toNativeUtf8();
    try {
      _d.check(
        _d.createAIVoltageChan(_task, phys, empty, DaqMx.valDefault, -range, range, DaqMx.valVolts, nullptr),
        'CreateAIVoltageChan',
      );
      if (_c.clockMode == CdaqClockMode.importMasterClock) {
        final src = _c.clockSource.toNativeUtf8();
        try {
          _d.check(_d.setMasterTimebaseSrc(_task, src), 'MasterTimebaseSrc');
          _d.check(_d.setMasterTimebaseRate(_task, _c.extClockHz), 'MasterTimebaseRate');
        } finally {
          calloc.free(src);
        }
      }
      _d.check(
        _d.cfgSampClkTiming(_task, empty, _c.fixedRate, DaqMx.valRising, DaqMx.valContSamps, 1 << 20),
        'CfgSampClkTiming',
      );
      _d.check(_d.startTask(_task), 'StartTask');
    } finally {
      calloc.free(phys);
      calloc.free(empty);
    }
    _streamPos = 0;
    _running = true;
  }

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    if ((fs - _c.fixedRate).abs() > 1e-6) {
      throw DigitizerException('cDAQ sampling rate is fixed to ${_c.fixedRate} Sa/s in the digitizer configuration.');
    }
    if (trigger.source != TriggerSource.immediate) throw DigitizerException('cDAQ supports immediate trigger only.');
    if (_c.clockMode == CdaqClockMode.exportMasterClock) {
      throw DigitizerException('"Export master clock" mode is not implemented in this port yet.');
    }
    _n = samplesCount;
    _trigger = trigger;
    await _startStream();
  }

  @override
  Future<void> initiate() async {
    _pos = 0;
    _abort = false;
    // discard samples acquired between records: record starts "now"
    final tot = calloc<Uint64>();
    try {
      _d.check(_d.getReadTotalSampPerChanAcquired(_task, tot), 'ReadTotalSampPerChanAcquired');
      _startIndex = tot.value;
    } finally {
      calloc.free(tot);
    }
    await _skipTo(_startIndex);
  }

  Future<void> _skipTo(int index) async {
    while (_streamPos < index) {
      final n = math.min(index - _streamPos, 100000);
      _read(n, 1.0);
    }
  }

  Float64List _read(int n, double timeout) {
    final nch = _c.channelIds.length;
    final buf = calloc<Double>(n * nch);
    final got = calloc<Int32>();
    try {
      _d.check(
        _d.readAnalogF64(_task, n, timeout, DaqMx.valGroupByScanNumber, buf, n * nch, got, nullptr),
        'ReadAnalogF64',
      );
      _streamPos += got.value;
      return Float64List.fromList(buf.asTypedList(got.value * nch));
    } finally {
      calloc.free(buf);
      calloc.free(got);
    }
  }

  /// 24 bit integer scale for the +-0.5 V range.
  double get _gain => range / (1 << 23);

  @override
  Future<FetchResult> fetch() async {
    if (_abort) {
      return FetchResult(
        done: true,
        status: DigitizerStatus(done: true, fetched: _pos, total: _n, message: 'aborted'),
      );
    }
    final nch = _c.channelIds.length;
    final chunk = math.min(_n - _pos, math.max(500, (_c.fixedRate * 0.2).round()));
    final v = _read(chunk, chunk / _c.fixedRate + 2);
    final out = Int32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = (v[i] / _gain).round();
    }
    final pk = DataPacket(out, nch, _pos);
    _pos += pk.count;
    final done = _pos >= _n;
    return FetchResult(
      packet: pk,
      aux: AuxData(
        gains: List.filled(nch, _gain),
        offsets: List.filled(nch, 0),
        timestamps: List.filled(nch, _startIndex / _c.fixedRate),
        increment: 1 / _c.fixedRate,
      ),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  @override
  Future<void> abort() async => _abort = true;

  @override
  Future<void> cleanup() async {}

  @override
  Future<void> close({bool resetToPreset = true}) async {
    if (_running) {
      _d.stopTask(_task);
      _d.clearTask(_task);
      _running = false;
    }
    _open = false;
  }

  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: _n,
    channelsCount: _c.channelIds.length,
    fs: _c.fixedRate,
    ranges: List.filled(_c.channelIds.length, range),
    trigger: _trigger,
    bitResolution: 24,
    deviceAttributes: [
      DeviceAttribute('master clock mode', [_c.clockMode.name]),
    ],
  );

  @override
  String info() =>
      'NI 9238 in ${_c.device}, ${_c.channelIds.length} channel(s), fixed ${_c.fixedRate} Sa/s, '
      'continuous background digitizing (time stamps).\nDriver not verified on real instruments.';
}
