import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:twm_model/twm_model.dart';

import '../digitizer/simulated_digitizer.dart';
import '../measurement/measurement_engine.dart';
import '../qwtb/dart_algorithms.dart';
import '../qwtb/dart_processor.dart';
import '../session/session_writer.dart';
import '../store/file_store.dart';
import 'shared.dart';

/// Backend running completely in the browser (no server, no GNU Octave,
/// no instruments): simulated digitizer, measurement sessions in the
/// browser storage, Dart ports of the QWTB algorithms.
class BrowserBackend implements TwmBackend {
  final FileStore store;

  /// Settings persistence (e.g. localStorage); null = in memory only.
  final Future<String?> Function()? loadSettingsText;
  final Future<void> Function(String)? saveSettingsText;

  static const home = '/';
  static const sessionsFolder = '/measurements';
  static const correctionsFolder = '/corrections';

  final _events = StreamController<BackendEvent>.broadcast();
  MeasurementEngine? _engine;
  bool _stopProcessing = false;
  late final DartProcessor _proc = DartProcessor(store);

  BrowserBackend(this.store, {this.loadSettingsText, this.saveSettingsText});

  void _emit(BackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  String get description => 'browser';

  @override
  BackendFeatures get features => BackendFeatures.browser;

  @override
  Stream<BackendEvent> get events => _events.stream;

  // ------------------------------------------------------------ settings --

  AppSettings defaults() {
    final s = AppSettings();
    s.measurement
      ..folder = sessionsFolder
      ..nameBase = 'meas_%id%'
      ..processingEnabled = true
      ..processing = ProcessingSetup(algorithmId: 'TWM-PSFE', mode: ProcessingMode.qwtb);
    s.corrections.transducersRoot = '$correctionsFolder/transducers';
    s.digitizer.simulated.realtimeFactor = 1;
    return s;
  }

  @override
  Future<AppSettings> loadSettings() async {
    try {
      final t = await loadSettingsText?.call();
      if (t != null && t.isNotEmpty) {
        final s = AppSettings.fromJson(jsonDecode(t) as Json);
        s.digitizer.type = DigitizerType.simulated;
        return s;
      }
    } catch (_) {}
    return defaults();
  }

  @override
  Future<void> saveSettings(AppSettings s) async => saveSettingsText?.call(jsonEncode(s.toJson()));

  // --------------------------------------------------------------- files --

  @override
  Future<DirListing> listDir(String path, {List<String> extensions = const []}) async {
    await store.mkdirs(sessionsFolder);
    return listDirOf(
      store,
      path,
      extensions: extensions,
      roots: const [home, sessionsFolder, correctionsFolder],
      home: sessionsFolder,
    );
  }

  @override
  Future<String> readText(String path) => store.readText(path);

  @override
  Future<void> writeText(String path, String content) => store.writeText(path, content);

  @override
  Future<bool> exists(String path) => store.exists(path);

  /// ZIP archive of a folder (download of a measurement session).
  Future<Uint8List> exportZip(String folder) async {
    final root = await store.isDirectory(folder) ? folder : store.path.dirname(folder);
    final a = Archive();
    for (final e in await store.list(root, recursive: true)) {
      if (e.isDir) continue;
      final rel = store.path.relative(e.path, from: store.path.dirname(root));
      final b = await store.readBytes(e.path);
      a.addFile(ArchiveFile(rel, b.length, b));
    }
    return Uint8List.fromList(ZipEncoder().encode(a));
  }

  /// Extracts ZIP (session or corrections) into [destFolder]; returns
  /// paths of the extracted `session.info` files.
  Future<List<String>> importZip(Uint8List bytes, String destFolder) async {
    final a = ZipDecoder().decodeBytes(bytes);
    final sessions = <String>[];
    for (final f in a.files) {
      if (!f.isFile) continue;
      final rel = f.name.replaceAll('\\', '/');
      if (rel.split('/').contains('..')) continue;
      final path = store.path.join(destFolder, rel);
      await store.writeBytes(path, Uint8List.fromList(f.content));
      if (rel.endsWith('session.info')) sessions.add(path);
    }
    return sessions;
  }

  /// Writes an uploaded file.
  Future<void> upload(String path, Uint8List bytes) => store.writeBytes(path, bytes);

  Future<Uint8List> download(String path) => store.readBytes(path);

  Future<void> delete(String path) => store.delete(path, recursive: true);

  // ----------------------------------------------------------- digitizer --

  @override
  Future<DigitizerTestResult> testDigitizer(DigitizerConfig cfg) async {
    if (cfg.type != DigitizerType.simulated) {
      return DigitizerTestResult(
        ok: false,
        message:
            '${cfg.type.label} is not available in the browser version - use the desktop application '
            'on the PC with the instruments.',
      );
    }
    final d = SimulatedDigitizer(cfg.copy());
    await d.initialize();
    return DigitizerTestResult(
      ok: true,
      channelIdns: d.channelIdns,
      capabilities: d.capabilities(),
      message: 'OK - ${d.channelIdns.length} simulated channel(s).',
    );
  }

  @override
  Future<String> digitizerInfo(DigitizerConfig cfg) async => cfg.type == DigitizerType.simulated
      ? SimulatedDigitizer(cfg.copy()).info()
      : '${cfg.type.label}: not available in the browser version.';

  @override
  Future<List<String>> enumerateDevices(DigitizerConfig cfg) async => const [];

  @override
  Future<void> selfCalibrate(DigitizerConfig cfg) async {}

  // --------------------------------------------------------- corrections --

  @override
  Future<CorrectionSummary> correctionSummary(String path) => correctionSummaryOf(store, path);

  // --------------------------------------------------------- measurement --

  @override
  bool get measuring => _engine?.running ?? false;

  String _root(MeasurementConfig cfg) => MeasurementEngine.sessionRoot(cfg, DateTime.now(), store.path);

  @override
  Future<List<String>> collidingFiles(MeasurementConfig cfg) => SessionWriter.collidingFiles(store, _root(cfg));

  @override
  Future<void> clearSession(MeasurementConfig cfg) => SessionWriter.clearSession(store, _root(cfg));

  @override
  Future<String> startMeasurement(AppSettings s) async {
    if (measuring) throw StateError('Measurement is already running.');
    if (s.digitizer.type != DigitizerType.simulated) {
      throw StateError('Only the simulated digitizer is available in the browser version.');
    }
    final dig = SimulatedDigitizer(s.digitizer.copy());
    final ps = s.measurement.processing;
    final engine = MeasurementEngine(
      store: store,
      digitizer: dig,
      digitizerConfig: s.digitizer,
      config: s.measurement,
      corrections: s.corrections,
      processor: s.measurement.processingEnabled ? (session, g, r, last) => _processRecord(session, ps, g, r) : null,
      monitorWindow: s.online.monitorWindowMs / 1000,
    );
    _engine = engine;
    final mapper = MeasEventMapper(store, s, _emit);
    final sub = engine.events.listen(mapper.handle);
    unawaited(
      engine.run().then((_) {}, onError: (_) {}).whenComplete(() async {
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
      }),
    );
    return _root(s.measurement);
  }

  @override
  Future<void> stopMeasurement() async {
    _engine?.stop();
    _stopProcessing = true;
  }

  // ------------------------------------------------------------ sessions --

  @override
  Future<SessionSummary> sessionSummary(String sessionPath) => sessionSummaryOf(store, sessionPath);

  @override
  Future<WaveformData> readRecord(String sessionPath, int group, int record, {int maxPoints = 5000}) =>
      readRecordOf(store, sessionPath, group, record, maxPoints);

  @override
  Future<SpectrumData> recordSpectrum(
    String sessionPath,
    int group,
    int record, {
    WindowType window = WindowType.hann,
    int maxPoints = 8192,
  }) => recordSpectrumOf(store, sessionPath, group, record, window, maxPoints);

  // ---------------------------------------------------------- processing --

  static const _noOctave =
      'GNU Octave is not available in the browser version - the Dart ports of the TWM '
      'algorithms are used instead.';

  @override
  Future<OctaveStatus> octaveStart(OctaveConfig cfg) async => const OctaveStatus(error: _noOctave);

  @override
  Future<OctaveStatus> octaveRestart(OctaveConfig cfg) async => const OctaveStatus(error: _noOctave);

  @override
  Future<OctaveStatus> octaveStatus() async => const OctaveStatus(error: _noOctave);

  @override
  Future<String> octaveEval(String code) async => throw UnsupportedError(_noOctave);

  @override
  Future<void> octaveInstallPackage(String file) async => throw UnsupportedError(_noOctave);

  @override
  Future<List<AlgorithmSummary>> algorithms() async => [
    for (final a in DartAlgorithm.all) AlgorithmSummary(a.info.id, a.info.name),
  ];

  @override
  Future<AlgorithmInfo> algorithmInfo(String id) async {
    final a = DartAlgorithm.byId(id);
    if (a == null) throw StateError('Algorithm $id is not available in the browser version.');
    return a.info;
  }

  Future<void> _processRecord(String session, ProcessingSetup ps, int group, int record) async {
    _emit(ProcessingEvent(session, record: record, busy: true));
    try {
      if (ps.mode == ProcessingMode.raw) throw UnsupportedError(_noOctave);
      await _proc.process(session, ps, group: group, record: record);
      _emit(ProcessingEvent(session, record: record));
    } catch (e) {
      _emit(ProcessingEvent(session, record: record, error: '$e'));
    }
  }

  @override
  Future<void> processRecords(
    String sessionPath,
    ProcessingSetup setup, {
    required int group,
    required List<int> records,
  }) async {
    _stopProcessing = false;
    await SessionWriter.writeQwtbSetup(store, store.path.dirname(sessionPath), setup);
    for (var k = 0; k < records.length; k++) {
      if (_stopProcessing) break;
      _emit(
        StatusEvent(
          'Processing record ${records[k]} (${k + 1}/${records.length})...',
          progress: k / records.length,
          record: k + 1,
          records: records.length,
        ),
      );
      await _processRecord(sessionPath, setup, group, records[k]);
      await Future<void>.delayed(Duration.zero); // keep UI responsive
    }
    _emit(StatusEvent(_stopProcessing ? 'Processing stopped' : 'Processing done', progress: 1));
  }

  @override
  Future<void> stopProcessing() async => _stopProcessing = true;

  @override
  Future<ResultsInfo> resultsInfo(String sessionPath, {String algorithm = ''}) =>
      _proc.resultsInfo(sessionPath, algorithm: algorithm);

  @override
  Future<ResultsTable> results(String sessionPath, String algorithm, ResultViewConfig cfg) =>
      _proc.results(sessionPath, algorithm, cfg);

  @override
  Future<ResultData> resultData(String sessionPath, String algorithm, ResultViewConfig cfg) =>
      _proc.resultData(sessionPath, algorithm, cfg);

  /// Coherent sampling search (integer number of periods in the record and
  /// the sampling rate on the digitizer grid).
  @override
  Future<({double fs, int n, double err})> findCoherent(
    double f0,
    double tMin,
    double tMax,
    Map<String, Object?> rate,
    double maxErr,
    double timeout,
  ) async {
    final fsMin = jDouble(rate['fs_min']);
    final fsMax = fsMin * (1 + jDouble(rate['fs_rel_tol']));
    final fsStep = jDouble(rate['fs_step'], 0);
    final tsStep = jDouble(rate['Ts_step'], 0);
    double grid(double fs) {
      if (tsStep > 0) return 1 / ((1 / fs / tsStep).round() * tsStep);
      if (fsStep > 0) return (fs / fsStep).round() * fsStep;
      return fs;
    }

    var best = (fs: grid(fsMin), n: (tMin * fsMin).round(), err: double.infinity);
    final sw = Stopwatch()..start();
    for (var p = math.max(1, (tMin * f0).ceil()); p <= math.max(1, (tMax * f0).floor()); p++) {
      // samples count giving fs close to the allowed range
      for (var n = (p * fsMin / f0).floor(); n <= (p * fsMax / f0).ceil(); n++) {
        if (n < 2) continue;
        final fs = grid(n * f0 / p);
        if (fs < fsMin * (1 - 1e-12) || fs > fsMax * (1 + 1e-12)) continue;
        final err = ((n / fs) * f0 - p).abs() / p;
        if (err < best.err) best = (fs: fs, n: n, err: err);
        if (err <= maxErr) return best;
      }
      if (sw.elapsedMilliseconds > timeout * 1000) break;
    }
    if (best.err > maxErr) throw StateError('No coherent setup found (best error ${best.err}).');
    return best;
  }

  Future<void> dispose() async {
    _engine?.stop();
    await _events.close();
  }
}
