import 'dart:async';

import '../json.dart';
import '../models/digitizer.dart';
import '../models/digitizer_config.dart';
import '../models/measurement.dart';
import '../models/qwtb.dart';
import 'backend.dart';
import 'events.dart';

/// [TwmBackend] implemented by JSON RPC calls (method + JSON args) handled
/// on the other side by `BackendDispatcher`. Transports: HTTP/WebSocket
/// (`RemoteBackend`, web client) and isolate ports (`IsolateBackend`,
/// desktop - keeps blocking driver calls out of the UI isolate).
abstract class RpcBackend implements TwmBackend {
  final eventsController = StreamController<BackendEvent>.broadcast();
  bool _measuring = false;

  /// Performs the call; returns the `result` value or throws.
  Future<Object?> invoke(String method, [Json args = const {}]);

  /// Transport implementations call this for every received event.
  void onEvent(Json e) {
    final ev = BackendEvent.fromJson(e);
    if (ev is StatusEvent && ev.record > 0) _measuring = true;
    if (ev is FinishedEvent) _measuring = false;
    if (!eventsController.isClosed) eventsController.add(ev);
  }

  Future<Json> _obj(String m, [Json a = const {}]) async => jMap(await invoke(m, a));

  @override
  Stream<BackendEvent> get events => eventsController.stream;

  @override
  bool get measuring => _measuring;

  set measuringState(bool v) => _measuring = v;

  @override
  Future<AppSettings> loadSettings() async => AppSettings.fromJson(await _obj('loadSettings'));

  @override
  Future<void> saveSettings(AppSettings s) => invoke('saveSettings', {'settings': s.toJson()});

  @override
  Future<DirListing> listDir(String path, {List<String> extensions = const []}) async =>
      DirListing.fromJson(await _obj('listDir', {'path': path, 'extensions': extensions}));

  @override
  Future<String> readText(String path) async => jString((await _obj('readText', {'path': path}))['text']);

  @override
  Future<void> writeText(String path, String content) => invoke('writeText', {'path': path, 'content': content});

  @override
  Future<bool> exists(String path) async => jBool((await _obj('exists', {'path': path}))['value']);

  @override
  Future<DigitizerTestResult> testDigitizer(DigitizerConfig cfg) async =>
      DigitizerTestResult.fromJson(await _obj('testDigitizer', {'cfg': cfg.toJson()}));

  @override
  Future<String> digitizerInfo(DigitizerConfig cfg) async =>
      jString((await _obj('digitizerInfo', {'cfg': cfg.toJson()}))['text']);

  @override
  Future<List<String>> enumerateDevices(DigitizerConfig cfg) async =>
      jStringList((await _obj('enumerateDevices', {'cfg': cfg.toJson()}))['list']);

  @override
  Future<void> selfCalibrate(DigitizerConfig cfg) => invoke('selfCalibrate', {'cfg': cfg.toJson()});

  @override
  Future<CorrectionSummary> correctionSummary(String path) async =>
      CorrectionSummary.fromJson(await _obj('correctionSummary', {'path': path}));

  @override
  Future<List<String>> collidingFiles(MeasurementConfig cfg) async =>
      jStringList((await _obj('collidingFiles', {'cfg': cfg.toJson()}))['list']);

  @override
  Future<void> clearSession(MeasurementConfig cfg) => invoke('clearSession', {'cfg': cfg.toJson()});

  @override
  Future<String> startMeasurement(AppSettings s) async {
    final r = jString((await _obj('startMeasurement', {'settings': s.toJson()}))['path']);
    _measuring = true;
    return r;
  }

  @override
  Future<void> stopMeasurement() => invoke('stopMeasurement');

  @override
  Future<SessionSummary> sessionSummary(String sessionPath) async =>
      SessionSummary.fromJson(await _obj('sessionSummary', {'path': sessionPath}));

  @override
  Future<WaveformData> readRecord(String sessionPath, int group, int record, {int maxPoints = 5000}) async =>
      WaveformData.fromJson(
        await _obj('readRecord', {'path': sessionPath, 'group': group, 'record': record, 'maxPoints': maxPoints}),
      );

  @override
  Future<OctaveStatus> octaveStart(OctaveConfig cfg) async =>
      OctaveStatus.fromJson(await _obj('octaveStart', {'cfg': cfg.toJson()}));

  @override
  Future<OctaveStatus> octaveRestart(OctaveConfig cfg) async =>
      OctaveStatus.fromJson(await _obj('octaveRestart', {'cfg': cfg.toJson()}));

  @override
  Future<OctaveStatus> octaveStatus() async => OctaveStatus.fromJson(await _obj('octaveStatus'));

  @override
  Future<String> octaveEval(String code) async => jString((await _obj('octaveEval', {'code': code}))['text']);

  @override
  Future<void> octaveInstallPackage(String file) => invoke('octaveInstallPackage', {'path': file});

  @override
  Future<List<AlgorithmSummary>> algorithms() async => [
    for (final a in jMapList((await _obj('algorithms'))['list'])) AlgorithmSummary.fromJson(a),
  ];

  @override
  Future<AlgorithmInfo> algorithmInfo(String id) async =>
      AlgorithmInfo.fromJson(await _obj('algorithmInfo', {'id': id}));

  @override
  Future<void> processRecords(
    String sessionPath,
    ProcessingSetup setup, {
    required int group,
    required List<int> records,
  }) => invoke('processRecords', {'path': sessionPath, 'setup': setup.toJson(), 'group': group, 'records': records});

  @override
  Future<void> stopProcessing() => invoke('stopProcessing');

  @override
  Future<ResultsInfo> resultsInfo(String sessionPath, {String algorithm = ''}) async =>
      ResultsInfo.fromJson(await _obj('resultsInfo', {'path': sessionPath, 'algorithm': algorithm}));

  @override
  Future<ResultsTable> results(String sessionPath, String algorithm, ResultViewConfig cfg) async =>
      ResultsTable.fromJson(await _obj('results', {'path': sessionPath, 'algorithm': algorithm, 'cfg': cfg.toJson()}));

  @override
  Future<ResultData> resultData(String sessionPath, String algorithm, ResultViewConfig cfg) async =>
      ResultData.fromJson(await _obj('resultData', {'path': sessionPath, 'algorithm': algorithm, 'cfg': cfg.toJson()}));

  @override
  Future<({double fs, int n, double err})> findCoherent(
    double f0,
    double tMin,
    double tMax,
    Map<String, Object?> rate,
    double maxErr,
    double timeout,
  ) async {
    final r = await _obj('findCoherent', {
      'f0': f0,
      'tMin': tMin,
      'tMax': tMax,
      'rate': rate,
      'maxErr': maxErr,
      'timeout': timeout,
    });
    return (fs: jDouble(r['fs']), n: jInt(r['n']), err: jDouble(r['err'], double.nan));
  }
}
