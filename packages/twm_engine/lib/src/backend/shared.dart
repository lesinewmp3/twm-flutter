import 'dart:async';

import 'package:twm_model/twm_model.dart';

import '../measurement/measurement_engine.dart';
import '../session/session_reader.dart';
import '../store/file_store.dart';

/// Converts measurement engine events to backend events: live spectra,
/// on-line analysis (TPQA) and saving of its results. Shared by the
/// desktop/server backend and the browser backend.
class MeasEventMapper {
  final FileStore store;
  final AppSettings settings;
  final OnlineAnalyzer online;
  final void Function(BackendEvent) emit;

  /// Live data (waveforms, spectra, status) is sent at most once per [liveInterval]:
  /// a fast continuous acquisition (e.g. 1000 short records/s) otherwise floods
  /// the UI. The newest data is always delivered, the on-line analysis still
  /// takes every record.
  final Duration liveInterval;

  MeasEventMapper(this.store, this.settings, this.emit, {this.liveInterval = const Duration(milliseconds: 100)})
    : online = OnlineAnalyzer(settings.online);

  late final _waveforms = _Throttle(liveInterval);
  late final _statuses = _Throttle(liveInterval);

  Future<void> handle(MeasEvent e) async {
    final s = settings;
    switch (e) {
      case MeasStatus():
        _statuses.add(() => emit(StatusEvent(e.message, progress: e.progress, record: e.record, records: e.records)));
      case MeasRecordData():
        final full = e.full;
        OnlineResult? res;
        if (s.online.enabled && full != null) {
          try {
            res = online.analyze(full, 1 / e.fullTs, s.corrections.transducers);
            final f = s.online.resultsFile;
            if (s.online.saveResults && f.isNotEmpty) {
              final head = await store.exists(f) ? '' : '${onlineCsvHeader(res)}\n';
              await store.appendText(f, '$head${onlineCsvRow(res, e.record, DateTime.now())}\n');
            }
          } catch (err) {
            emit(StatusEvent('On-line analysis failed: $err'));
          }
        }
        _waveforms.add(() => emit(_waveform(e, res)));
      case MeasRecordStored():
        emit(RecordStoredEvent(e.sessionPath, e.group, e.record));
      case MeasFinished():
        // the last record and status first
        _statuses.flush();
        _waveforms.flush();
        emit(FinishedEvent(e.sessionPath, aborted: e.aborted, error: e.error?.toString() ?? ''));
    }
  }

  WaveformEvent _waveform(MeasRecordData e, OnlineResult? res) {
    final spectra = <List<double>>[];
    var df = 0.0;
    final full = e.full;
    if (full != null && full.isNotEmpty) {
      for (final c in full) {
        final sp = Spectrum.of(c, 1 / e.fullTs, window: settings.online.window);
        df = sp.df;
        spectra.add(sp.forDisplay(4096));
      }
      // display decimation of the spectrum changes the bin width
      final n = full.first.length ~/ 2 + 1;
      if (spectra.first.length < n) df *= (n / spectra.first.length).ceilToDouble();
    }
    return WaveformEvent(
      e.record,
      e.names,
      [for (final c in e.channels) c.toList()],
      e.ts,
      spectra: spectra,
      df: df,
      online: res?.toJson(),
    );
  }
}

/// Runs the first action at once, then at most one per [interval]; actions
/// arriving in between replace each other and the newest runs at the end of
/// the interval.
class _Throttle {
  final Duration interval;
  final _clock = Stopwatch();
  void Function()? _pending;
  Timer? _timer;
  _Throttle(this.interval);

  void add(void Function() action) {
    if (_timer != null) {
      _pending = action;
      return;
    }
    if (!_clock.isRunning || _clock.elapsed >= interval) {
      _run(action);
    } else {
      _pending = action;
      _timer = Timer(interval - _clock.elapsed, flush);
    }
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final a = _pending;
    _pending = null;
    if (a != null) _run(a);
  }

  void _run(void Function() action) {
    _clock
      ..reset()
      ..start();
    action();
  }
}

/// Session structure for the batch processing and record viewer panels.
Future<SessionSummary> sessionSummaryOf(FileStore store, String sessionPath) async {
  final r = await SessionReader.open(store, sessionPath);
  final h = r.header;
  final recs = [for (var g = 1; g <= r.groupsCount; g++) r.repetitions(g)];
  final tags = <String>[];
  final cs = h.sectionOrNull('measurement setup configuration');
  if (cs != null) {
    final paths = cs.textMatrixOrNull('transducer paths') == null ? <String>[] : cs.textList('transducer paths');
    final ph = cs.matrixOrNull('channel phase indexes') == null ? <double>[] : cs.vector('channel phase indexes');
    for (var k = 0; k < paths.length; k++) {
      var type = 'divider';
      try {
        final f = store.path.join(r.root, paths[k].replaceAll('\\', '/'));
        type = Info.parse(await store.readText(f)).text('type');
      } catch (_) {}
      tags.add('${type == 'shunt' ? 'i' : 'u'}${k < ph.length ? ph[k].round() : k + 1}');
    }
  }
  final g1 = r.groupsCount > 0 ? r.group(1) : Info();
  return SessionSummary(
    path: store.path.join(r.root, 'session.info'),
    channels: r.channelDescriptors,
    recordsPerGroup: recs,
    transducerTags: tags,
    comment: h.textMatrixOrNull('measurement comment') == null ? '' : h.textList('measurement comment').join('\n'),
    fs: g1.numberOrNull('sampling rate [Sa/s]') ?? 0,
    samplesCount: (g1.numberOrNull('samples count') ?? 0).round(),
  );
}

Future<WaveformData> readRecordOf(FileStore store, String sessionPath, int group, int record, int maxPoints) async {
  final r = await SessionReader.open(store, sessionPath);
  final d = await r.readRecord(group, record, maxPoints: maxPoints);
  return WaveformData(d.names, [for (final c in d.channels) c.toList()], d.ts, d.fullLength);
}

/// Summary of a correction INFO file in the store.
Future<CorrectionSummary> correctionSummaryOf(FileStore store, String path) async {
  try {
    final i = Info.parse(await store.readText(path));
    return CorrectionSummary(
      path: path,
      type: i.textOrNull('type') ?? '',
      name: i.textOrNull('name') ?? '',
      serial: i.textOrNull('serial number') ?? '',
      nominalRatio: i.numberOrNull('nominal ratio') ?? double.nan,
      channelIdentifiers: i.textMatrixOrNull('channel identifiers') == null
          ? const []
          : i.textList('channel identifiers'),
    );
  } catch (e) {
    return CorrectionSummary(path: path, error: '$e');
  }
}

/// Directory listing of the store for the file browser.
Future<DirListing> listDirOf(
  FileStore store,
  String path, {
  List<String> extensions = const [],
  List<String> roots = const [],
  String home = '/',
}) async {
  final pc = store.path;
  var dir = path.isEmpty ? home : path;
  if (await store.exists(dir) && !await store.isDirectory(dir)) dir = pc.dirname(dir);
  if (!await store.isDirectory(dir)) dir = home;
  final entries = <FileEntry>[];
  for (final e in await store.list(dir)) {
    final name = pc.basename(e.path);
    if (name.startsWith('.')) continue;
    if (!e.isDir && extensions.isNotEmpty && !extensions.any((x) => name.toLowerCase().endsWith(x.toLowerCase()))) {
      continue;
    }
    entries.add(FileEntry(name, e.path, e.isDir, size: e.size, modified: e.modified));
  }
  entries.sort(
    (a, b) => a.isDir != b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  return DirListing(pc.normalize(dir), pc.dirname(dir), pc.separator, entries, roots);
}
