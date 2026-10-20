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

  /// Full resolution data for the on-line analyser (may be null if too big).
  final List<Float64List>? full;
  final double fullTs;
  const MeasRecordData(this.record, this.channels, this.ts, this.names, this.full, this.fullTs);
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

  /// Max samples per channel passed as full data to the on-line analyser.
  final int fullDataLimit;

  final _events = StreamController<MeasEvent>.broadcast();
  bool _stop = false;
  bool _running = false;

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

  /// Runs the whole measurement. Completes when finished/aborted.
  Future<String> run({DateTime? now}) async {
    if (_running) throw StateError('Measurement already running');
    _running = true;
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
        final preview = <List<Float64List>>[];
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
              final a = await _acquire(rf, preview, r, records, s * muxCycles + m, subs * muxCycles);
              if (a == null) break;
              aux ??= a;
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
        _emitRecordData(r, preview, aux);

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
          if (config.processingEnabled && processor != null) {
            _status('Processing record $r...', progress: 1, record: r, records: records);
            await processor!(sessionFile, group, r, records != 0 && r == records);
          }
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
    List<List<Float64List>> preview,
    int r,
    int records,
    int sub,
    int subCount,
  ) async {
    await digitizer.initiate();
    AuxData? aux;
    final chunks = <DataPacket>[];
    var fetched = 0;
    while (true) {
      final res = await digitizer.fetch();
      if (res.aux != null) aux = res.aux;
      final pk = res.packet;
      if (pk != null && pk.count > 0) {
        await rf?.write(pk);
        fetched += pk.count;
        chunks.add(pk);
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
    if (aux != null && sub == 0) {
      preview.add(_scaleChunks(chunks, aux));
    }
    return aux;
  }

  List<Float64List> _scaleChunks(List<DataPacket> chunks, AuxData aux) {
    if (chunks.isEmpty) return [];
    final ch = chunks.first.channels;
    final n = chunks.fold<int>(0, (s, c) => s + c.count);
    final out = List.generate(ch, (_) => Float64List(n));
    var pos = 0;
    for (final c in chunks) {
      for (var i = 0; i < c.count; i++) {
        for (var k = 0; k < ch; k++) {
          out[k][pos + i] = c.samples[i * ch + k] * aux.gains[k] + aux.offsets[k];
        }
      }
      pos += c.count;
    }
    return out;
  }

  void _emitRecordData(int r, List<List<Float64List>> preview, AuxData aux) {
    if (preview.isEmpty || preview.first.isEmpty) return;
    final full = preview.first;
    final n = full.first.length;
    final step = n > previewPoints ? (n / previewPoints).ceil() : 1;
    final dec = [
      for (final c in full) step == 1 ? c : Float64List.fromList([for (var i = 0; i < n; i += step) c[i]]),
    ];
    _events.add(
      MeasRecordData(
        r,
        dec,
        aux.increment * step,
        digitizer.channelIdns,
        n <= fullDataLimit ? full : null,
        aux.increment,
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
