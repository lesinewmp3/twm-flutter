import 'dart:async';
import 'dart:math' as math;

import 'package:twm_model/twm_model.dart';

import '../measurement/measurement_engine.dart';
import '../session/session_reader.dart';
import '../store/file_store.dart';
import 'record_analysis.dart';

/// Converts measurement engine events to backend events: live spectra,
/// on-line analysis (TPQA) and saving of its results. Shared by the
/// desktop/server backend and the browser backend.
class MeasEventMapper {
  final FileStore store;
  final AppSettings settings;
  final void Function(BackendEvent) emit;

  /// Spectra and on-line analysis of the records, one at a time in their
  /// order. The acquisition never waits for it: when it is slower than the
  /// records, only the newest record waits and the older ones are skipped.
  final RecordAnalyzer analyzer;
  MeasRecordData? _waiting;
  bool _analyzing = false;
  int _skipped = 0;
  Completer<void>? _idle;

  /// Live data (waveforms, spectra, status) is sent at most once per [liveInterval]:
  /// a fast continuous acquisition (e.g. 1000 short records/s) otherwise floods
  /// the UI. The newest data is always delivered, the on-line analysis still
  /// takes every record.
  final Duration liveInterval;

  MeasEventMapper(
    this.store,
    this.settings,
    this.emit, {
    this.liveInterval = const Duration(milliseconds: 100),
    RecordAnalyzer? analyzer,
  }) : analyzer = analyzer ?? InlineRecordAnalyzer(settings);

  late final _waveforms = _Throttle(liveInterval);
  late final _statuses = _Throttle(liveInterval);
  final _monitor = _Throttle(const Duration(milliseconds: 25));

  Future<void> handle(MeasEvent e) async {
    switch (e) {
      case MeasStatus():
        _statuses.add(() => emit(StatusEvent(e.message, progress: e.progress, record: e.record, records: e.records)));
      case MeasRecordData():
        final full = e.full;
        if (full == null || full.isEmpty) {
          _waveforms.add(() => emit(_waveform(e, const RecordAnalysis())));
          return;
        }
        if (_waiting != null) _skipped++;
        _waiting = e;
        _analyzeNext();
      case MeasLiveData():
        final f = e.frame;
        _monitor.add(
          () => emit(
            LiveEvent(
              e.record,
              e.names,
              [for (final c in f.channels) c.toList()],
              f.dx,
              x0: f.x0,
              span: f.span,
              triggered: f.triggered,
            ),
          ),
        );
      case MeasRecordStored():
        emit(RecordStoredEvent(e.sessionPath, e.group, e.record));
      case MeasFinished():
        // the last record and status first
        if (_analyzing || _waiting != null) await (_idle ??= Completer<void>()).future;
        await analyzer.close();
        if (_skipped > 0) {
          _statuses.add(() => emit(StatusEvent('On-line analysis skipped $_skipped records (slower than the acquisition)')));
        }
        _monitor.flush();
        _statuses.flush();
        _waveforms.flush();
        emit(FinishedEvent(e.sessionPath, aborted: e.aborted, error: e.error?.toString() ?? ''));
    }
  }

  void _analyzeNext() {
    final e = _waiting;
    if (_analyzing || e == null) return;
    _waiting = null;
    _analyzing = true;
    unawaited(() async {
      try {
        final a = await analyzer.analyze(e.full!, 1 / e.fullTs);
        final s = settings, res = a.online;
        if (a.error.isNotEmpty) emit(StatusEvent('On-line analysis failed: ${a.error}'));
        if (res != null && s.online.saveResults && s.online.resultsFile.isNotEmpty) {
          final f = s.online.resultsFile;
          final head = await store.exists(f) ? '' : '${onlineCsvHeader(res)}\n';
          await store.appendText(f, '$head${onlineCsvRow(res, e.record, DateTime.now())}\n');
        }
        _waveforms.add(() => emit(_waveform(e, a)));
      } catch (err) {
        emit(StatusEvent('On-line analysis failed: $err'));
      } finally {
        _analyzing = false;
        if (_waiting != null) {
          _analyzeNext();
        } else {
          _idle?.complete();
          _idle = null;
        }
      }
    }());
  }

  WaveformEvent _waveform(MeasRecordData e, RecordAnalysis a) => WaveformEvent(
    e.record,
    e.names,
    [for (final c in e.channels) c.toList()],
    e.ts,
    spectra: [for (final sp in a.spectra) sp.toList()],
    df: a.df,
    online: a.online?.toJson(),
  );
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
    // checked here and not only by the timer: a busy event loop delays timers
    if (!_clock.isRunning || _clock.elapsed >= interval) {
      _timer?.cancel();
      _timer = null;
      _pending = null;
      _run(action);
      return;
    }
    _pending = action;
    _timer ??= Timer(interval - _clock.elapsed, flush);
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

Future<WaveformData> readRecordOf(
  FileStore store,
  String sessionPath,
  int group,
  int record,
  int maxPoints, {
  int from = 0,
  int count = 0,
}) async {
  final r = await SessionReader.open(store, sessionPath);
  final d = await r.readRecord(group, record, maxPoints: maxPoints, from: from, count: count);
  return WaveformData(
    d.names,
    [for (final c in d.channels) c.toList()],
    d.ts,
    d.fullLength,
    x0: d.from * d.fullTs,
    fullTs: d.fullTs,
  );
}

Future<SpectrumData> recordSpectrumOf(
  FileStore store,
  String sessionPath,
  int group,
  int record,
  WindowType window,
  int maxPoints,
) async {
  final r = await SessionReader.open(store, sessionPath);
  final d = await r.readRecord(group, record);
  final amps = <List<double>>[];
  var df = 0.0;
  for (final c in d.channels) {
    final sp = Spectrum.of(c, 1 / d.ts, window: window);
    final y = sp.forDisplay(maxPoints);
    amps.add(y);
    df = sp.df * (sp.amp.length / math.max(1, y.length)).ceilToDouble();
    if (y.length == sp.amp.length) df = sp.df;
  }
  return SpectrumData(d.names, amps, df, d.fullLength);
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
