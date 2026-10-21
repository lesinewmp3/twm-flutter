import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

import 'package:twm_engine/twm_engine.dart';
import '../drivers/auxiliary/multiplexers.dart';
import '../store/io_file_store.dart';
import '../octave/octave_bridge.dart';
import '../octave/qwtb_service.dart';

/// Locations of the application resources (m-files, example corrections)
/// and of the settings file.
class AppPaths {
  /// Folder with `octave/` and `data/` of this project.
  final String home;
  final String settingsFile;

  AppPaths(this.home, this.settingsFile);

  String get octaveRoot => p.join(home, 'octave');
  String get octprog => p.join(octaveRoot, 'octprog');
  String get corrections => p.join(home, 'data', 'corrections');

  /// Looks for the project home: $TWM_HOME, next to the executable, or
  /// in the parents of the current directory.
  static AppPaths resolve({String? home, String? settingsFile}) {
    String? found = home ?? Platform.environment['TWM_HOME'];
    if (found == null) {
      final candidates = <String>[];
      var d = p.dirname(Platform.resolvedExecutable);
      for (var i = 0; i < 6; i++) {
        candidates.add(d);
        candidates.add(p.join(d, 'data', 'flutter_assets', 'assets'));
        d = p.dirname(d);
      }
      d = Directory.current.path;
      for (var i = 0; i < 6; i++) {
        candidates.add(d);
        d = p.dirname(d);
      }
      for (final c in candidates) {
        if (File(p.join(c, 'octave', 'api', 'twm_api.m')).existsSync()) {
          found = c;
          break;
        }
      }
    }
    found ??= Directory.current.path;
    final cfgDir = Platform.isWindows
        ? p.join(Platform.environment['APPDATA'] ?? found, 'TWM-Flutter')
        : p.join(Platform.environment['HOME'] ?? found, '.config', 'twm_flutter');
    return AppPaths(found, settingsFile ?? p.join(cfgDir, 'settings.json'));
  }
}

/// In-process implementation of [TwmBackend] (desktop and server).
class LocalBackend implements TwmBackend {
  final AppPaths paths;
  final _store = IoFileStore();
  final _events = StreamController<BackendEvent>.broadcast();

  VirtualDigitizer? _digitizer;
  MeasurementEngine? _engine;
  OctaveBridge? _octave;
  QwtbService? _qwtb;
  StreamSubscription<ConsoleLine>? _consoleSub;
  bool _stopProcessing = false;
  Timer? _closeTimer;

  LocalBackend(this.paths);

  @override
  String get description => 'local';

  @override
  BackendFeatures get features => BackendFeatures.full;

  @override
  Stream<BackendEvent> get events => _events.stream;

  void _emit(BackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ------------------------------------------------------------ settings --

  AppSettings _defaults() {
    final s = AppSettings();
    s.octave.octprogPath = paths.octprog;
    s.octave.qwtbPath = p.join(paths.octprog, 'qwtb');
    s.octave.packages = ['io', 'signal', 'statistics', 'optim'];
    s.measurement.folder = p.join(
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.',
      'TWM measurements',
    );
    s.corrections.transducersRoot = p.join(paths.corrections, 'transducers');
    return s;
  }

  @override
  Future<AppSettings> loadSettings() async {
    final f = File(paths.settingsFile);
    if (!f.existsSync()) return _defaults();
    try {
      final s = AppSettings.fromJson(jsonDecode(await f.readAsString()) as Json);
      if (s.octave.octprogPath.isEmpty || !Directory(s.octave.octprogPath).existsSync()) {
        s.octave.octprogPath = paths.octprog;
        s.octave.qwtbPath = p.join(paths.octprog, 'qwtb');
      }
      // the bundled corrections move with the app (AppImage mounts at a new path each run)
      if (s.corrections.transducersRoot.isEmpty || !Directory(s.corrections.transducersRoot).existsSync()) {
        s.corrections.transducersRoot = p.join(paths.corrections, 'transducers');
      }
      return s;
    } catch (_) {
      return _defaults();
    }
  }

  @override
  Future<void> saveSettings(AppSettings s) async {
    final f = File(paths.settingsFile);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  }

  // --------------------------------------------------------------- files --

  @override
  Future<DirListing> listDir(String path, {List<String> extensions = const []}) async {
    var dir = path.isEmpty ? (Platform.environment['HOME'] ?? Directory.current.path) : path;
    if (await FileSystemEntity.isFile(dir)) dir = p.dirname(dir);
    if (!Directory(dir).existsSync()) dir = Directory.current.path;
    final entries = <FileEntry>[];
    await for (final e in Directory(dir).list(followLinks: false)) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      final isDir = e is Directory;
      if (!isDir && extensions.isNotEmpty && !extensions.any((x) => name.toLowerCase().endsWith(x.toLowerCase()))) {
        continue;
      }
      FileStat? st;
      try {
        st = await e.stat();
      } catch (_) {}
      entries.add(FileEntry(name, e.path, isDir, size: st?.size ?? 0, modified: st?.modified));
    }
    entries.sort(
      (a, b) => a.isDir != b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    final roots = <String>[
      if (Platform.environment['HOME'] != null) Platform.environment['HOME']!,
      if (Platform.environment['USERPROFILE'] != null) Platform.environment['USERPROFILE']!,
      paths.corrections,
      if (Platform.isWindows)
        for (final l in 'CDEFGH'.split(''))
          if (Directory('$l:\\').existsSync()) '$l:\\' else '/',
    ];
    return DirListing(p.normalize(dir), p.dirname(dir), p.separator, entries, roots);
  }

  @override
  Future<String> readText(String path) => File(path).readAsString(encoding: latin1);

  @override
  Future<void> writeText(String path, String content) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  @override
  Future<bool> exists(String path) async => await File(path).exists() || await Directory(path).exists();

  // ----------------------------------------------------------- digitizer --

  /// Returns the digitizer instance for [cfg], reusing the open one when
  /// the type matches (TWM keeps DMMs open with "delayed reset").
  Future<VirtualDigitizer> _getDigitizer(DigitizerConfig cfg) async {
    final d = _digitizer;
    if (d != null) {
      final sameType = d.config.type == cfg.type;
      final sameCfg = jsonEncode(d.config.toJson()) == jsonEncode(cfg.toJson());
      if (sameType && sameCfg) return d;
      try {
        await d.close();
      } catch (_) {}
      _digitizer = null;
    }
    final n = DigitizerFactory.create(cfg.copy());
    await n.initializeDriver();
    _digitizer = n;
    return n;
  }

  void _scheduleClose(DigitizerConfig cfg) {
    _closeTimer?.cancel();
    if (cfg.onClose == OnCloseAction.delayedReset) {
      _closeTimer = Timer(Duration(seconds: cfg.delayedResetTimeout.round()), () async {
        if (_engine?.running ?? false) return;
        try {
          await _digitizer?.close(resetToPreset: true);
        } catch (_) {}
      });
    }
  }

  @override
  Future<DigitizerTestResult> testDigitizer(DigitizerConfig cfg) async {
    try {
      final d = await _getDigitizer(cfg);
      await d.initialize(reset: cfg.forceResetOnOpen);
      final caps = d.capabilities();
      _scheduleClose(cfg);
      return DigitizerTestResult(
        ok: true,
        channelIdns: d.channelIdns,
        auxIdns: d.auxIdns,
        capabilities: caps,
        message: 'OK - ${d.channelIdns.length} channel(s) found.',
      );
    } catch (e) {
      return DigitizerTestResult(ok: false, message: '$e');
    }
  }

  @override
  Future<String> digitizerInfo(DigitizerConfig cfg) async {
    try {
      final d = DigitizerFactory.create(cfg.copy());
      return d.info();
    } catch (e) {
      return '$e';
    }
  }

  @override
  Future<List<String>> enumerateDevices(DigitizerConfig cfg) async {
    final d = await _getDigitizer(cfg);
    return d.enumerateDevices();
  }

  @override
  Future<void> selfCalibrate(DigitizerConfig cfg) async {
    final d = await _getDigitizer(cfg);
    if (!d.isOpen) await d.initialize();
    await d.selfCalibrate();
  }

  // --------------------------------------------------------- corrections --

  @override
  Future<CorrectionSummary> correctionSummary(String path) async {
    try {
      final i = Info.parse(await readText(path));
      final type = i.textOrNull('type') ?? '';
      return CorrectionSummary(
        path: path,
        type: type,
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

  // --------------------------------------------------------- measurement --

  @override
  bool get measuring => _engine?.running ?? false;

  @override
  Future<List<String>> collidingFiles(MeasurementConfig cfg) async =>
      SessionWriter.collidingFiles(_store, MeasurementEngine.sessionRoot(cfg, DateTime.now()));

  @override
  Future<void> clearSession(MeasurementConfig cfg) =>
      SessionWriter.clearSession(_store, MeasurementEngine.sessionRoot(cfg, DateTime.now()));

  @override
  Future<String> startMeasurement(AppSettings s) async {
    if (measuring) throw StateError('Measurement is already running.');
    _closeTimer?.cancel();
    final dig = await _getDigitizer(s.digitizer);
    Multiplexer? mux;
    if (s.digitizer.multiplexer.enabled) {
      mux = createMultiplexer(s.digitizer.multiplexer, dig);
      await mux.open();
    }
    final ps = s.measurement.processing;
    final mapper = MeasEventMapper(_store, s, _emit);
    final engine = MeasurementEngine(
      store: _store,
      digitizer: dig,
      digitizerConfig: s.digitizer,
      config: s.measurement,
      corrections: s.corrections,
      multiplexer: mux,
      processor: s.measurement.processingEnabled
          ? (session, g, r, last) => _processRecord(session, ps, s.octave, g, r, last)
          : null,
    );
    _engine = engine;
    final sub = engine.events.listen(mapper.handle);
    final done = engine.run().whenComplete(() async {
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await mux?.close();
      _scheduleClose(s.digitizer);
    });
    unawaited(done.then((_) {}, onError: (_) {}));
    return MeasurementEngine.sessionRoot(s.measurement, DateTime.now());
  }

  @override
  Future<void> stopMeasurement() async {
    _engine?.stop();
    _stopProcessing = true;
  }

  // ------------------------------------------------------------ sessions --

  @override
  Future<SessionSummary> sessionSummary(String sessionPath) => sessionSummaryOf(_store, sessionPath);

  @override
  Future<WaveformData> readRecord(String sessionPath, int group, int record, {int maxPoints = 5000}) =>
      readRecordOf(_store, sessionPath, group, record, maxPoints);

  // ---------------------------------------------------------- processing --

  OctaveBridge _bridge(OctaveConfig cfg) {
    var o = _octave;
    if (o == null) {
      o = OctaveBridge(cfg, apiRoot: paths.octaveRoot);
      _consoleSub = o.console.listen((l) => _emit(ConsoleEvent(l.text, isError: l.isError, isCommand: l.isCommand)));
      _octave = o;
      _qwtb = QwtbService(o);
    } else {
      o.config = cfg;
    }
    return o;
  }

  QwtbService get _q {
    final q = _qwtb;
    if (q == null) throw OctaveException('GNU Octave/Matlab is not configured. Open "Octave/Matlab" settings.');
    return q;
  }

  Future<QwtbService> _ensureQwtb() async {
    if (_qwtb == null) {
      final s = await loadSettings();
      _bridge(s.octave);
    }
    return _q;
  }

  OctaveStatus _status(OctaveBridge o, [String error = '']) {
    final i = o.initInfo ?? {};
    List<String> l(Object? v) => v is List ? [for (final e in v) '$e'] : (v is String ? [v] : []);
    return OctaveStatus(
      running: o.isRunning,
      version: '${i['version'] ?? ''}',
      isOctave: i['is_octave'] != false,
      installedPackages: l(i['installed']),
      loadedPackages: l(i['loaded']),
      failedPackages: l(i['failed']),
      hasQwtb: i['has_qwtb'] == true,
      error: error,
    );
  }

  @override
  Future<OctaveStatus> octaveStart(OctaveConfig cfg) async {
    final o = _bridge(cfg);
    try {
      await o.start();
      return _status(o);
    } catch (e) {
      return _status(o, '$e');
    }
  }

  @override
  Future<OctaveStatus> octaveRestart(OctaveConfig cfg) async {
    final o = _bridge(cfg);
    await o.stop();
    return octaveStart(cfg);
  }

  @override
  Future<OctaveStatus> octaveStatus() async {
    final o = _octave;
    return o == null ? const OctaveStatus() : _status(o);
  }

  @override
  Future<String> octaveEval(String code) async {
    await _ensureQwtb();
    await _octave!.start();
    return _octave!.eval(code);
  }

  @override
  Future<void> octaveInstallPackage(String file) async {
    await octaveEval("pkg('install', ${OctaveBridge.toLiteral(file)});");
  }

  @override
  Future<List<AlgorithmSummary>> algorithms() async => (await _ensureQwtb()).algorithms();

  @override
  Future<AlgorithmInfo> algorithmInfo(String id) async => (await _ensureQwtb()).algorithm(id);

  Future<void> _processRecord(
    String session,
    ProcessingSetup ps,
    OctaveConfig oc,
    int group,
    int record,
    bool last,
  ) async {
    _bridge(oc);
    _emit(ProcessingEvent(session, record: record, busy: true));
    try {
      if (ps.mode == ProcessingMode.raw) {
        final out = await _q.raw(session, ps.rawCode, group: group, record: record);
        _emit(ConsoleEvent(out));
      } else {
        final unc = ps.uncertaintyOnce && record > 1 ? 'none' : '';
        await _q.exec(
          session,
          record: record,
          group: group,
          isLast: last,
          uncertainty: unc,
          setup: ps,
          timeout: Duration(seconds: ps.timeout.round()),
        );
      }
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
    final s = await loadSettings();
    await _ensureQwtb();
    final root = p.dirname(sessionPath);
    if (setup.mode == ProcessingMode.qwtb) {
      await SessionWriter.writeQwtbSetup(_store, root, setup);
    }
    _stopProcessing = false;
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
      await _processRecord(sessionPath, setup, s.octave, group, records[k], k == records.length - 1);
    }
    _emit(StatusEvent(_stopProcessing ? 'Processing stopped' : 'Processing done', progress: 1));
  }

  @override
  Future<void> stopProcessing() async {
    _stopProcessing = true;
    await _octave?.interrupt();
  }

  @override
  Future<ResultsInfo> resultsInfo(String sessionPath, {String algorithm = ''}) async {
    final root = p.dirname(sessionPath);
    if (!File(p.join(root, 'results.info')).existsSync()) return ResultsInfo.empty;
    return (await _ensureQwtb()).resultsInfo(root, algorithm: algorithm);
  }

  @override
  Future<ResultsTable> results(String sessionPath, String algorithm, ResultViewConfig cfg) async =>
      (await _ensureQwtb()).results(p.dirname(sessionPath), algorithm, cfg);

  @override
  Future<ResultData> resultData(String sessionPath, String algorithm, ResultViewConfig cfg) async =>
      (await _ensureQwtb()).resultData(p.dirname(sessionPath), algorithm, cfg);

  @override
  Future<({double fs, int n, double err})> findCoherent(
    double f0,
    double tMin,
    double tMax,
    Map<String, Object?> rate,
    double maxErr,
    double timeout,
  ) async => (await _ensureQwtb()).findCoherent(f0, tMin, tMax, rate, maxErr, timeout);

  Future<void> dispose() async {
    _closeTimer?.cancel();
    _engine?.stop();
    await _consoleSub?.cancel();
    await _octave?.dispose();
    try {
      await _digitizer?.close();
    } catch (_) {}
    await _events.close();
  }
}
