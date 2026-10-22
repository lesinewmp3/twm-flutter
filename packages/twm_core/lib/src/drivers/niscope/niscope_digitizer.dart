import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';
import 'niscope_lib.dart';

/// NI PXI-5922 (niScope) virtual digitizer, one or more cards synchronized
/// by NI-TClk (TWM "niScope Virtual Digitizer", TPQA
/// `niScope_GenericMultiDeviceConfiguredAcquisitionTClk`).
///
/// NOT VERIFIED ON REAL INSTRUMENTS (developed without hardware).
class NiScopeDigitizer extends VirtualDigitizer {
  NiScopeDigitizer(super.config);

  final Map<String, int> _vi = {}; // resource -> session
  bool _open = false;
  double _fs = 1e6;
  int _n = 0;
  TriggerConfig _trigger = TriggerConfig();
  List<double> _ranges = [];
  int _pos = 0;
  List<double>? _stamps; // relative timestamps of the record (first fetch)
  bool _abort = false;
  bool _armed = false;
  final _sw = Stopwatch();

  NiScopeConfig get _c => config.niScope;
  NiScopeLib get _l => NiScopeLib.instance;

  @override
  bool get isOpen => _open;

  /// Channels grouped per card (resource) in configuration order.
  Map<String, List<int>> get _groups {
    final g = <String, List<int>>{};
    for (final c in _c.channels) {
      g.putIfAbsent(c.resource, () => []).add(c.channelId);
    }
    return g;
  }

  @override
  Future<void> initialize({bool reset = false}) async {
    if (_open) await close(resetToPreset: false);
    final p = calloc<Uint32>();
    try {
      for (final r in _groups.keys) {
        final rs = r.toNativeUtf8();
        try {
          _l.check(0, _l.init(rs, 1, reset ? 1 : 0, p), 'init($r)');
        } finally {
          calloc.free(rs);
        }
        _vi[r] = p.value;
      }
      channelIdns = [for (final c in _c.channels) 'NI 5922 ${c.resource}, channel ${c.channelId}'];
      auxIdns = [];
      _ranges = [for (final c in _c.channels) c.range];
      _open = true;
    } catch (_) {
      await close(resetToPreset: false);
      rethrow;
    } finally {
      calloc.free(p);
    }
  }

  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) => DigitizerCapabilities(
    // 5922: 256 MB/channel onboard memory option -> 64 MS (int32); streaming unlimited
    maxSamplesCount: _c.streaming ? 1 << 31 : 32 * 1024 * 1024,
    maxFs: 15e6,
    minFs: 50e3,
    // sample rate = 60 MHz / n for flexres sampling
    tsStep: 1 / 60e6,
    stepMode: SampleRateStepMode.constPeriod,
    channelsCount: _c.channels.length,
    allowsStreaming: true,
    streamingOn: _c.streaming,
    // streaming: continuous acquisition without a trigger (as TWM)
    hasLevelTrig: !_c.streaming,
    hasExtTrig: !_c.streaming,
    hasRanges: true,
    hasSelfCal: true,
    ranges: const [1, 2, 5, 10],
  );

  /// Record length configured on the cards in the streaming mode: the
  /// reference trigger never comes, so the cards acquire continuously and the
  /// samples are fetched behind the read pointer (NI-SCOPE "Fetch Forever",
  /// TWM streaming); the record is only the pretrigger buffer and fits the
  /// smallest onboard memory.
  static const _streamRecord = 1 << 20;

  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async {
    if (!_open) throw DigitizerException('niScope digitizer not initialized.');
    _n = samplesCount;
    _trigger = trigger;
    if (ranges.length == _c.channels.length) _ranges = ranges;
    final g = _groups;
    final record = _c.streaming ? math.min(_n, _streamRecord) : _n;
    // streaming: all of the record is pretrigger buffer, acquired continuously
    // while waiting for the trigger that never comes (0 % would keep nothing)
    final refPosition = _c.streaming ? 100.0 : _c.trigger.refPosition;
    for (final e in g.entries) {
      final vi = _vi[e.key]!;
      final acq = _c.acquisitionType == NiScopeAcquisitionType.flexres ? NiScope.valFlexres : NiScope.valNormal;
      _l.check(vi, _l.configureAcquisition(vi, acq), 'ConfigureAcquisition');
      for (final chId in [0, 1]) {
        final idx = _c.channels.indexWhere((c) => c.resource == e.key && c.channelId == chId);
        final name = '$chId'.toNativeUtf8();
        try {
          if (idx < 0) {
            // unused channels grounded (prevents noise buildup)
            _l.check(vi, _l.configureVertical(vi, name, 2, 0, NiScope.valGnd, 1, 0), 'ConfigureVertical(gnd)');
            continue;
          }
          final ch = _c.channels[idx];
          final coupling = switch (ch.coupling) {
            NiScopeCoupling.dc => NiScope.valDc,
            NiScopeCoupling.ac => NiScope.valAc,
            NiScopeCoupling.gnd => NiScope.valGnd,
          };
          // niScope vertical range is peak-to-peak
          _l.check(
            vi,
            _l.configureVertical(vi, name, 2 * _ranges[idx], ch.offset, coupling, ch.probeAttenuation, 1),
            'ConfigureVertical',
          );
          _l.check(
            vi,
            _l.configureChanCharacteristics(
              vi,
              name,
              ch.inputZ == NiScopeInputZ.ohm50 ? 50 : 1e6,
              ch.maxInputFrequency,
            ),
            'ConfigureChanCharacteristics',
          );
        } finally {
          calloc.free(name);
        }
      }
      _l.check(
        vi,
        _l.configureHorizontalTiming(vi, fs, record, refPosition, 1, 1),
        'ConfigureHorizontalTiming',
      );
      // PLL reference: the external clock, or none = internal clock (set also
      // for the internal one, the card keeps the last setting)
      final src = _c.extClockHz > 0
          ? switch (_c.extClockSource) {
              NiScopeClockSource.clkIn => 'VAL_CLK_IN',
              NiScopeClockSource.pxiClk => 'VAL_PXI_CLK',
              NiScopeClockSource.pfi0 => 'VAL_PFI_0',
              NiScopeClockSource.pfi1 => 'VAL_PFI_1',
              NiScopeClockSource.none => 'VAL_NO_SOURCE',
            }
          : 'VAL_NO_SOURCE';
      final empty = ''.toNativeUtf8();
      final s = src.toNativeUtf8();
      try {
        _l.check(vi, _l.setString(vi, empty, NiScope.attrInputClockSource, s), 'ref clock source');
        if (_c.extClockHz > 0) {
          _l.check(vi, _l.setReal(vi, empty, NiScope.attrRefClkRate, _c.extClockHz), 'ref clock rate');
        }
        if (_c.streaming) {
          _l.check(
            vi,
            _l.setInt(vi, empty, NiScope.attrFetchRelativeTo, NiScope.valReadPointer),
            'fetch relative to read pointer',
          );
        }
      } finally {
        calloc.free(empty);
        calloc.free(s);
      }
      _configureTrigger(vi, first: e.key == g.keys.first);
      // settings checked by the card now, not at the start of the measurement
      _l.check(vi, _l.commit(vi), 'Commit');
    }
    if (_vi.length > 1) {
      final arr = _sessions();
      try {
        _l.checkTclk(_l.tclkConfigureForHomogeneousTriggers(_vi.length, arr), 'niTClk_ConfigureForHomogeneousTriggers');
        _l.checkTclk(_l.tclkSynchronize(_vi.length, arr, 0.0), 'niTClk_Synchronize');
      } finally {
        calloc.free(arr);
      }
    }
    final r = calloc<Double>();
    try {
      _l.check(_vi.values.first, _l.sampleRate(_vi.values.first, r), 'SampleRate');
      _fs = r.value;
    } finally {
      calloc.free(r);
    }
  }

  Pointer<Uint32> _sessions() {
    final arr = calloc<Uint32>(_vi.length);
    var i = 0;
    for (final v in _vi.values) {
      arr[i++] = v;
    }
    return arr;
  }

  void _configureTrigger(int vi, {required bool first}) {
    final a = _c.trigger;
    final slope = _trigger.slope == TriggerSlope.positive ? NiScope.valPositive : NiScope.valNegative;
    final coupling = _trigger.coupling == TriggerCoupling.dc ? NiScope.valDc : NiScope.valAc;
    // with TClk only the first card has a real trigger, others follow
    if (_c.streaming && first) {
      // a software trigger that is never sent: continuous acquisition
      _l.check(vi, _l.configureTriggerSoftware(vi, 0, 0), 'ConfigureTriggerSoftware');
      return;
    }
    // (a software trigger in a single shot would never come: immediate)
    final immediate = a.type == NiScopeTriggerType.immediate || a.type == NiScopeTriggerType.software;
    if (!first || _c.streaming || (_trigger.source == TriggerSource.immediate && immediate)) {
      _l.check(vi, _l.configureTriggerImmediate(vi), 'ConfigureTriggerImmediate');
      return;
    }
    final type = !immediate
        ? a.type
        : (_trigger.source == TriggerSource.external ? NiScopeTriggerType.digital : NiScopeTriggerType.edge);
    final src =
        (!immediate
                ? a.source
                : (_trigger.source == TriggerSource.external ? 'VAL_EXTERNAL' : '${_c.channels.first.channelId}'))
            .toNativeUtf8();
    try {
      switch (type) {
        case NiScopeTriggerType.edge:
          _l.check(
            vi,
            _l.configureTriggerEdge(vi, src, _trigger.level, slope, coupling, a.holdoff, a.delay),
            'ConfigureTriggerEdge',
          );
        case NiScopeTriggerType.hysteresis:
          _l.check(
            vi,
            _l.configureTriggerHysteresis(vi, src, _trigger.level, a.hysteresis, slope, coupling, a.holdoff, a.delay),
            'ConfigureTriggerHysteresis',
          );
        case NiScopeTriggerType.window:
          _l.check(
            vi,
            _l.configureTriggerWindow(
              vi,
              src,
              a.lowLevel,
              a.highLevel,
              a.windowEntering ? NiScope.valEntering : NiScope.valLeaving,
              coupling,
              a.holdoff,
              a.delay,
            ),
            'ConfigureTriggerWindow',
          );
        case NiScopeTriggerType.digital:
          _l.check(vi, _l.configureTriggerDigital(vi, src, slope, a.holdoff, a.delay), 'ConfigureTriggerDigital');
        case NiScopeTriggerType.software || NiScopeTriggerType.immediate:
          _l.check(vi, _l.configureTriggerImmediate(vi), 'ConfigureTriggerImmediate');
      }
    } finally {
      calloc.free(src);
    }
  }

  @override
  Future<void> initiate() async {
    _pos = 0;
    _stamps = null;
    _abort = false;
    if (_vi.length > 1) {
      final arr = _sessions();
      try {
        _l.checkTclk(_l.tclkInitiate(_vi.length, arr), 'niTClk_Initiate');
      } finally {
        calloc.free(arr);
      }
    } else {
      final vi = _vi.values.first;
      _l.check(vi, _l.initiate(vi), 'InitiateAcquisition');
    }
    _sw
      ..reset()
      ..start();
    _armed = true;
  }

  bool _complete() {
    final st = calloc<Int32>();
    try {
      for (final vi in _vi.values) {
        _l.check(vi, _l.acquisitionStatus(vi, st), 'AcquisitionStatus');
        if (st.value != NiScope.valAcqComplete) return false;
      }
      return true;
    } finally {
      calloc.free(st);
    }
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
    int chunk;
    double timeout;
    if (_c.streaming) {
      // short blocking fetches keep the caller responsive and the read pointer
      // well within the record buffer of the cards
      chunk = math.min(_n - _pos, math.max(1000, math.min(_streamRecord ~/ 4, (_fs * 0.2).round())));
      timeout = chunk / _fs + 1;
    } else {
      if (!_complete()) {
        if (_sw.elapsedMilliseconds > (_c.fetchTimeout * 1000 + _n / _fs * 1000)) {
          throw DigitizerException('niScope acquisition timeout (trigger not received?).');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return FetchResult(status: DigitizerStatus(sampling: true, fetched: 0, total: _n));
      }
      chunk = _n;
      timeout = 5;
    }
    final nch = _c.channels.length;
    final out = Int32List(chunk * nch);
    final gains = List<double>.filled(nch, 1);
    final offsets = List<double>.filled(nch, 0);
    final stamps = List<double>.filled(nch, 0);
    var inc = 1 / _fs;
    for (final e in _groups.entries) {
      final vi = _vi[e.key]!;
      final ids = e.value;
      final list = ids.join(',').toNativeUtf8();
      final buf = calloc<Int32>(chunk * ids.length);
      final info = calloc<WfmInfo>(ids.length);
      try {
        _l.check(vi, _l.fetchBinary32(vi, list, timeout, chunk, buf, info), 'FetchBinary32');
        for (var k = 0; k < ids.length; k++) {
          final idx = _c.channels.indexWhere((c) => c.resource == e.key && c.channelId == ids[k]);
          final wi = info[k];
          gains[idx] = wi.gain;
          offsets[idx] = wi.offset;
          stamps[idx] = wi.relativeInitialX;
          inc = wi.xIncrement;
          final w = buf + k * chunk;
          for (var i = 0; i < chunk; i++) {
            out[i * nch + idx] = w[i];
          }
        }
      } finally {
        calloc.free(list);
        calloc.free(buf);
        calloc.free(info);
      }
    }
    // timestamps of the record = of its first samples (streaming: first fetch;
    // no trigger, so relative to the first channel as TWM)
    final st = _stamps ??= _c.streaming ? [for (final t in stamps) t - stamps.first] : stamps;
    final pk = DataPacket(out, nch, _pos);
    _pos += chunk;
    final done = _pos >= _n;
    return FetchResult(
      packet: pk,
      aux: AuxData(gains: gains, offsets: offsets, timestamps: st, increment: inc),
      done: done,
      status: DigitizerStatus(sampling: !done, done: done, fetched: _pos, total: _n),
    );
  }

  @override
  Future<void> abort() async {
    _abort = true;
    for (final vi in _vi.values) {
      _l.abort(vi);
    }
  }

  @override
  Future<void> cleanup() async {
    _armed = false;
    for (final vi in _vi.values) {
      _l.abort(vi);
    }
  }

  @override
  Future<void> close({bool resetToPreset = true}) async {
    for (final vi in _vi.values) {
      try {
        if (resetToPreset) _l.reset(vi);
        _l.close(vi);
      } catch (_) {}
    }
    _vi.clear();
    _open = false;
  }

  @override
  Future<void> selfCalibrate() async {
    if (!_open) await initialize();
    for (final vi in _vi.values) {
      final empty = ''.toNativeUtf8();
      try {
        _l.check(vi, _l.calSelf(vi, empty, NiScope.calOptionStandard), 'CalSelfCalibrate');
      } finally {
        calloc.free(empty);
      }
    }
  }

  /// Exports the reference clock to a PFI line, the other is released
  /// (multiplexer control, TWM "niScope Set PFI": Disable, Export Signal,
  /// Commit). [terminal] null = no output.
  void exportPfi(int channelIndex, String? terminal) {
    final res = _c.channels[channelIndex].resource;
    final vi = _vi[res];
    if (vi == null) throw DigitizerException('niScope session not open for multiplexer.');
    _l.check(vi, _l.disable(vi), 'Disable');
    if (terminal != null) {
      final id = ''.toNativeUtf8();
      final t = terminal.toNativeUtf8();
      try {
        _l.check(vi, _l.exportSignal(vi, NiScope.valRefClock, id, t), 'ExportSignal($terminal)');
      } finally {
        calloc.free(id);
        calloc.free(t);
      }
    }
    _l.check(vi, _l.commit(vi), 'Commit');
  }

  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: _n,
    channelsCount: _c.channels.length,
    fs: _fs,
    ranges: _ranges,
    trigger: _trigger,
    extFreqLocked: _c.extClockHz > 0,
    streaming: _c.streaming,
    // 5922 flexible resolution: 24 bit at <= 500 kSa/s, 16 bit at 15 MSa/s
    bitResolution: _fs <= 500e3 ? 24 : (_fs <= 5e6 ? 20 : 16),
    deviceAttributes: [
      DeviceAttribute('input impedance [Ohm]', [
        for (final c in _c.channels) c.inputZ == NiScopeInputZ.ohm50 ? '50' : '1000000',
      ]),
      DeviceAttribute('reference clock [Hz]', ['${_c.extClockHz}']),
    ],
  );

  @override
  String info() =>
      '${_groups.length} x NI PXI-5922 card(s), ${_c.channels.length} channel(s)'
      '${_groups.length > 1 ? ', synchronized by NI-TClk' : ''}.\n'
      '${_c.extClockHz > 0 ? 'PLL locked to ${_c.extClockHz} Hz reference.\n' : 'Internal clock.\n'}'
      'Driver not verified on real instruments.';
}
