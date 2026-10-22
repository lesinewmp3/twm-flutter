import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

import '../digitizer/virtual_digitizer.dart';
import '../multiplexer/multiplexer.dart';
import '../session/record_file.dart';
import '../session/session_writer.dart';
import '../store/file_store.dart';
import 'live_collector.dart';
import 'live_monitor.dart';

/// Events emitted by the running measurement (status line, progress bar,
/// waveform preview, new record/result notifications).
sealed class MeasEvent {
  const MeasEvent();
}

class MeasStatus extends MeasEvent {
  final String message;
  final double progress; // 0..1 of current record
  final int record; // 1-based, 0 = not started
  final int records; // 0 = unlimited (continuous)
  const MeasStatus(this.message, {this.progress = 0, this.record = 0, this.records = 0});
}

/// Scaled data of the last acquired record (decimated for display).
class MeasRecordData extends MeasEvent {
  final int record;
  final List<Float64List> channels;
  final double ts;
  final List<String> names;

  /// Full resolution data for the on-line analyser: the whole record or its
  /// first [MeasurementEngine.fullDataLimit] samples (see [recordSamples]).
  final List<Float64List>? full;
  final double fullTs;

  /// Samples per channel of the whole record (0 = same as [full]).
  final int recordSamples;
  const MeasRecordData(
    this.record,
    this.channels,
    this.ts,
    this.names,
    this.full,
    this.fullTs, {
    this.recordSamples = 0,
  });
}

/// Live monitor frame of the record being acquired (see [LiveMonitor]).
class MeasLiveData extends MeasEvent {
  final int record;
  final LiveFrame frame;
  final List<String> names;
  const MeasLiveData(this.record, this.frame, this.names);
}

class MeasRecordStored extends MeasEvent {
  final String sessionPath;
  final int group;
  final int record;
  const MeasRecordStored(this.sessionPath, this.group, this.record);
}

class MeasFinished extends MeasEvent {
  final String sessionPath;
  final bool aborted;
  final Object? error;
  const MeasFinished(this.sessionPath, {this.aborted = false, this.error});
}

typedef RecordProcessor = Future<void> Function(String sessionFile, int group, int record, bool isLast);

/// Acquisition module (TWM "Meas Main" + "Meas Sequence Loop" +
/// "Meas Single Record"). Runs the virtual digitizer, streams the samples
/// to the session folder and optionally calls the processing for each
/// record.
class MeasurementEngine {
  final FileStore store;
  final VirtualDigitizer digitizer;
  final DigitizerConfig digitizerConfig;
  final MeasurementConfig config;
  final CorrectionsConfig corrections;
  final RecordProcessor? processor;
  final Multiplexer? multiplexer;

  /// Max points per channel of preview data.
  final int previewPoints;

  /// Max samples per channel passed as full data to the on-line analyser
  /// (longer records are analysed by their beginning).
  final int fullDataLimit;

  /// Live monitor window [s] (0 = no live frames) and the shortest time
  /// between two frames.
  final double monitorWindow;
  final Duration monitorInterval;

  final _events = StreamController<MeasEvent>.broadcast();
  bool _stop = false;
  bool _running = false;
  final _sinceYield = Stopwatch()..start();
  final _sinceLive = Stopwatch()..start();
  bool _liveTriggered = false; // the last live frame stood on the trigger
  AuxData? _lastAux; // scaling for live frames of drivers giving it at the record end

  MeasurementEngine({
    required this.store,
    required this.digitizer,
    required this.digitizerConfig,
    required this.config,
    required this.corrections,
    this.processor,
    this.multiplexer,
    this.previewPoints = 4000,
    this.fullDataLimit = 2000000,
    this.monitorWindow = 0,
    this.monitorInterval = const Duration(milliseconds: 25),
  });

  Stream<MeasEvent> get events => _events.stream;
  bool get running => _running;

  /// Session folder for [config] at time [now].
  static String sessionRoot(MeasurementConfig c, DateTime now, [p.Context? ctx]) =>
      (ctx ?? p.context).join(c.folder, c.resolveName(now));

  void stop() {
    _stop = true;
    unawaited(digitizer.abort());
  }

  void _status(String m, {double progress = 0, int record = 0, int records = 0}) =>
      _events.add(MeasStatus(m, progress: progress, record: record, records: records));

  /// Lets the event loop run (stop requests, timers, RPC, UI frames in the
  /// browser) when the digitizer returns data without waiting: `await` on
  /// completed futures only runs microtasks and would starve everything else.
  Future<void> _breathe() async {
    if (_sinceYield.elapsedMilliseconds < 8) return;
    await Future<void>.delayed(Duration.zero);
    _sinceYield.reset();
  }

  /// Runs the whole measurement. Completes when finished/aborted.
  Future<String> run({DateTime? now}) async {
    if (_running) throw StateError('Measurement already running');
    _running = true;
    _liveTriggered = false;
    _stop = false;
    final t0 = now ?? DateTime.now();
    final save = config.saveRecords || !config.continuous;
    final root = save ? sessionRoot(config, t0, store.path) : '';
    final sessionFile = save ? store.path.join(root, 'session.info') : '';
    Object? error;
    try {
      _status('Initializing digitizer...');
      if (!digitizer.isOpen) {
        await digitizer.initialize(reset: digitizerConfig.forceResetOnOpen);
      }
      final caps = digitizer.capabilities(fs: config.fs, aperture: config.aperture);
      final fs = caps.coerceFs(config.fs);
      final mux = digitizerConfig.multiplexer;
      final muxCycles = mux.enabled ? mux.sequence.length : 1;
      final subs = math.max(1, config.subRecordsCount);
      final ranges = config.ranges(digitizerConfig.defaultRanges);
      if (config.samplesCount > caps.maxSamplesCount) {
        throw DigitizerException(
          'Samples count ${config.samplesCount} exceeds digitizer limit ${caps.maxSamplesCount}.',
        );
      }

      _status('Configuring digitizer...');
      await digitizer.setup(
        fs: fs,
        samplesCount: config.samplesCount,
        trigger: config.trigger,
        aperture: config.aperture,
        ranges: ranges,
      );
      final setup = digitizer.currentSetup();

      SessionWriter? writer;
      var group = 0;
      if (save) {
        writer = SessionWriter(
          store: store,
          root: root,
          channelDescriptors: digitizer.channelIdns,
          auxDescriptors: digitizer.auxIdns,
          temperatureAvailable:
              caps.hasTemperature &&
              digitizerConfig.type == DigitizerType.hp3458a &&
              digitizerConfig.hp3458a.measureTemperature,
          temperatureLogAvailable: caps.hasTemperatureLog,
          sessionAttributes: [
            for (final a in setup.deviceAttributes)
              if (a.constPerGroup) a,
          ],
          multiplexer: mux,
          comment: config.comment,
        );
        await writer.storeCorrections(corrections, adcChannels: digitizer.channelIdns.length);
        group = writer.addGroup(
          GroupSetup(
            samplesCount: config.samplesCount,
            fs: setup.fs,
            ranges: setup.ranges,
            trigger: config.trigger,
            bitResolution: setup.bitResolution,
            subRecordsCount: subs,
            attributes: [
              for (final a in setup.deviceAttributes)
                if (!a.constPerGroup) a,
            ],
          ),
        );
        if (config.processingEnabled && config.processing.mode == ProcessingMode.qwtb) {
          await SessionWriter.writeQwtbSetup(store, root, config.processing);
        }
        await writer.save();
      }

      final records = config.continuous ? 0 : config.recordsCount;
      var stored = 0;
      for (var r = 1; records == 0 || r <= records; r++) {
        if (_stop) break;
        if (config.preRecordDelay > 0 && r > 1) {
          _status('Pre-record delay...', record: r, records: records);
          await _sleep(config.preRecordDelay);
          if (_stop) break;
        }
        final when = DateTime.now();
        RecordFileWriter? rf;
        if (save) {
          rf = await writer!.openRecord(group, r, int16: setup.isInt16);
        }
        final subOffsets = <int>[];
        final subStamps = <double>[];
        AuxData? aux;
        LiveCollector? live;
        var total = 0;
        try {
          for (var s = 0; s < subs && !_stop; s++) {
            for (var m = 0; m < muxCycles && !_stop; m++) {
              if (mux.enabled && multiplexer != null) {
                _status('Multiplexer -> ${mux.sequence[m]}', record: r, records: records);
                await multiplexer!.select(mux.sequence[m]);
                await _sleep(mux.delayAfterSwitch);
              }
              subOffsets.add(total);
              final sub = s * muxCycles + m;
              final lc = sub == 0
                  ? (live = LiveCollector(
                      channels: setup.channelsCount,
                      total: config.samplesCount,
                      previewPoints: previewPoints,
                      fullLimit: fullDataLimit,
                    ))
                  : null;
              final mon = sub == 0 && monitorWindow > 0
                  ? LiveMonitor(
                      channels: setup.channelsCount,
                      window: math.min((monitorWindow * setup.fs).round(), config.samplesCount).clamp(2, 1 << 21),
                    )
                  : null;
              final a = await _acquire(rf, lc, mon, r, records, sub, subs * muxCycles, setup.fullScaleCode);
              if (a == null) break;
              aux ??= a;
              _lastAux = a;
              subStamps.add(a.timestamps.isEmpty ? 0 : a.timestamps.first - aux.timestamps.first);
              total += config.samplesCount;
              if (mux.enabled && mux.delayBeforeSwitch > 0) await _sleep(mux.delayBeforeSwitch);
            }
          }
        } finally {
          await rf?.close();
          await digitizer.cleanup();
        }
        if (_stop || aux == null) break;

        // emit display data
        _emitRecordData(r, live, aux);

        if (save) {
          final hasSub = subs > 1 || mux.enabled;
          writer!.addRecord(
            group,
            recordFromAux(
              SessionWriter.recordRelPath(group, r),
              rf!.samplesWritten,
              aux,
              when,
              aperture: setup.aperture,
              subOffsets: hasSub ? subOffsets : const [],
              subTimestamps: hasSub ? subStamps : const [],
            ),
          );
          await writer.save();
          _events.add(MeasRecordStored(sessionFile, group, r));
          stored = r;
          if (config.processingEnabled && processor != null) {
            // parallel record processing only queues the record (no dead time)
            if (config.processing.execution == ExecutionMode.singleCore) {
              _status('Processing record $r...', progress: 1, record: r, records: records);
            }
            await processor!(sessionFile, group, r, records != 0 && r == records);
          }
        }
      }
      // continuous mode: STOP ends the averaging; an algorithm set to process
      // the whole average at once skipped every record up to now
      if (records == 0 && stored > 0 && config.processingEnabled && processor != null) {
        if (config.processing.wholeAverageAtOnce) {
          if (config.processing.execution == ExecutionMode.singleCore) {
            _status('Processing record $stored...', progress: 1, record: stored);
          }
          await processor!(sessionFile, group, stored, true);
        }
      }
    } catch (e) {
      error = e;
    } finally {
      try {
        if (digitizerConfig.onClose == OnCloseAction.immediateReset) {
          await digitizer.close(resetToPreset: true);
        }
      } catch (_) {}
      _running = false;
      _status(error != null ? 'Error: $error' : (_stop ? 'Stopped' : 'Done'));
      _events.add(MeasFinished(sessionFile, aborted: _stop, error: error));
    }
    if (error != null) throw error;
    return sessionFile;
  }

  Future<AuxData?> _acquire(
    RecordFileWriter? rf,
    LiveCollector? live,
    LiveMonitor? mon,
    int r,
    int records,
    int sub,
    int subCount,
    int fullScale,
  ) async {
    await digitizer.initiate();
    AuxData? aux;
    var fetched = 0;
    final overloaded = <int>{};
    while (true) {
      await _breathe();
      final res = await digitizer.fetch();
      if (res.aux != null) aux = res.aux;
      final pk = res.packet;
      if (pk != null && pk.count > 0) {
        if (fullScale > 0) _checkOverload(pk, fullScale, overloaded, r, records);
        await rf?.write(pk);
        fetched += pk.count;
        live?.add(pk);
        if (mon != null) {
          mon.add(pk);
          final sc = aux ?? _lastAux;
          // a new record starts with an empty buffer: its first frames are
          // short or not on the trigger, the screen keeps the last good frame
          // instead of jumping (a lost trigger shows after two windows)
          if (sc != null && mon.hasWindow && _sinceLive.elapsed >= monitorInterval) {
            _sinceLive.reset();
            final f = mon.frame(sc.gains, sc.offsets, sc.increment);
            if (f != null && (f.triggered || !_liveTriggered || mon.full)) {
              _liveTriggered = f.triggered;
              _events.add(MeasLiveData(r, f, digitizer.channelIdns));
            }
          }
        }
      }
      final prog = (sub + fetched / math.max(1, config.samplesCount)) / subCount;
      _status(
        'Digitizing record $r${records > 0 ? '/$records' : ''}...',
        progress: prog.clamp(0, 1).toDouble(),
        record: r,
        records: records,
      );
      if (res.done) break;
      if (_stop) {
        await digitizer.abort();
      }
    }
    if (_stop && fetched < config.samplesCount) return null;
    return aux;
  }

  /// Clipped samples make every result wrong without any visible sign in
  /// the numbers: stop the measurement unless the overload is ignored.
  void _checkOverload(DataPacket pk, int fullScale, Set<int> overloaded, int r, int records) {
    final s = pk.samples, ch = pk.channels;
    final before = overloaded.length;
    for (var c = 0; c < ch; c++) {
      if (overloaded.contains(c + 1)) continue;
      for (var i = c; i < s.length; i += ch) {
        final v = s[i];
        if (v >= fullScale || v <= -fullScale) {
          overloaded.add(c + 1);
          break;
        }
      }
    }
    if (overloaded.length == before) return;
    final list = (overloaded.toList()..sort()).join(', ');
    if (!digitizerConfig.ignoreOverload) {
      throw DigitizerException('Overload (clipped signal) of channel(s) $list - increase the range.');
    }
    _status('Warning: overload (clipped signal) of channel(s) $list', record: r, records: records);
  }

  void _emitRecordData(int r, LiveCollector? live, AuxData aux) {
    if (live == null || live.received == 0) return;
    final (preview, ts) = live.preview(aux.gains, aux.offsets, aux.increment);
    _events.add(
      MeasRecordData(
        r,
        preview,
        ts,
        digitizer.channelIdns,
        live.full(aux.gains, aux.offsets),
        aux.increment,
        recordSamples: live.received,
      ),
    );
  }

  Future<void> _sleep(double s) async {
    final end = DateTime.now().add(Duration(microseconds: (s * 1e6).round()));
    while (!_stop && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> dispose() => _events.close();
}
