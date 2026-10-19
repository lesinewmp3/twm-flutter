import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:twm_model/twm_model.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// [TwmBackend] client of a remote TWM server (`twm_server`): JSON RPC over
/// HTTP POST and events over WebSocket. Used by the web UI and optionally by
/// desktop UI controlling a measurement PC over network.
class RemoteBackend implements TwmBackend {
  final Uri base;
  final String? token;
  final _events = StreamController<BackendEvent>.broadcast();
  WebSocketChannel? _ws;
  bool _measuring = false;
  final _client = http.Client();

  RemoteBackend._(this.base, this.token);

  static Future<RemoteBackend> connect(String url, {String? token}) async {
    final b = RemoteBackend._(Uri.parse(url), token);
    b._connectEvents();
    try {
      b._measuring = jBool(jMap(await b._call('measuring'))['value']);
    } catch (_) {}
    return b;
  }

  void _connectEvents() {
    final wsUri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/events',
      queryParameters: token == null ? null : {'token': token},
    );
    final ws = WebSocketChannel.connect(wsUri);
    _ws = ws;
    ws.stream.listen(
      (m) {
        final e = BackendEvent.fromJson(jMap(jsonDecode(m as String)));
        if (e is StatusEvent && e.record > 0) _measuring = true;
        if (e is FinishedEvent) _measuring = false;
        _events.add(e);
      },
      onDone: () {
        _events.add(const StatusEvent('Connection to server lost - reconnecting...'));
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (!_events.isClosed) _connectEvents();
        });
      },
      onError: (_) {},
    );
  }

  Future<Object?> _call(String method, [Json args = const {}]) async {
    final r = await _client.post(
      base.replace(path: '/api/$method'),
      headers: {'content-type': 'application/json', if (token != null) 'authorization': 'Bearer $token'},
      body: jsonEncode(args),
    );
    if (r.statusCode != 200) throw Exception('Server error ${r.statusCode}: ${r.body}');
    final j = jMap(jsonDecode(utf8.decode(r.bodyBytes)));
    if (j['error'] != null) throw Exception(j['error']);
    return j['result'];
  }

  Future<Json> _obj(String m, [Json a = const {}]) async => jMap(await _call(m, a));

  @override
  String get description => 'server ${base.origin}';

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  bool get measuring => _measuring;

  @override
  Future<AppSettings> loadSettings() async => AppSettings.fromJson(await _obj('loadSettings'));

  @override
  Future<void> saveSettings(AppSettings s) => _call('saveSettings', {'settings': s.toJson()});

  @override
  Future<DirListing> listDir(String path, {List<String> extensions = const []}) async =>
      DirListing.fromJson(await _obj('listDir', {'path': path, 'extensions': extensions}));

  @override
  Future<String> readText(String path) async => jString((await _obj('readText', {'path': path}))['text']);

  @override
  Future<void> writeText(String path, String content) => _call('writeText', {'path': path, 'content': content});

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
  Future<void> selfCalibrate(DigitizerConfig cfg) => _call('selfCalibrate', {'cfg': cfg.toJson()});

  @override
  Future<CorrectionSummary> correctionSummary(String path) async =>
      CorrectionSummary.fromJson(await _obj('correctionSummary', {'path': path}));

  @override
  Future<List<String>> collidingFiles(MeasurementConfig cfg) async =>
      jStringList((await _obj('collidingFiles', {'cfg': cfg.toJson()}))['list']);

  @override
  Future<void> clearSession(MeasurementConfig cfg) => _call('clearSession', {'cfg': cfg.toJson()});

  @override
  Future<String> startMeasurement(AppSettings s) async {
    final r = jString((await _obj('startMeasurement', {'settings': s.toJson()}))['path']);
    _measuring = true;
    return r;
  }

  @override
  Future<void> stopMeasurement() => _call('stopMeasurement');

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
  Future<void> octaveInstallPackage(String file) => _call('octaveInstallPackage', {'path': file});

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
  }) => _call('processRecords', {'path': sessionPath, 'setup': setup.toJson(), 'group': group, 'records': records});

  @override
  Future<void> stopProcessing() => _call('stopProcessing');

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

  Future<void> dispose() async {
    await _ws?.sink.close();
    _client.close();
    await _events.close();
  }
}
