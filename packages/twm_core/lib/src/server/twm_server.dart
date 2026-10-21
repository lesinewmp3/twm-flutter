import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

/// Maps RPC calls (method name + JSON args) onto a [TwmBackend]. Used by
/// [TwmServer]; the client counterpart is `RemoteBackend` in the app.
class BackendDispatcher {
  final TwmBackend b;
  BackendDispatcher(this.b);

  Future<Object?> call(String method, Json a) async {
    DigitizerConfig dig() => DigitizerConfig.fromJson(jMap(a['cfg']));
    MeasurementConfig meas() => MeasurementConfig.fromJson(jMap(a['cfg']));
    OctaveConfig oct() => OctaveConfig.fromJson(jMap(a['cfg']));
    ResultViewConfig view() => ResultViewConfig.fromJson(jMap(a['cfg']));
    String path() => jString(a['path']);
    switch (method) {
      case 'loadSettings':
        return (await b.loadSettings()).toJson();
      case 'saveSettings':
        await b.saveSettings(AppSettings.fromJson(jMap(a['settings'])));
        return null;
      case 'listDir':
        return (await b.listDir(path(), extensions: jStringList(a['extensions']))).toJson();
      case 'readText':
        return {'text': await b.readText(path())};
      case 'writeText':
        await b.writeText(path(), jString(a['content']));
        return null;
      case 'exists':
        return {'value': await b.exists(path())};
      case 'testDigitizer':
        return (await b.testDigitizer(dig())).toJson();
      case 'digitizerInfo':
        return {'text': await b.digitizerInfo(dig())};
      case 'enumerateDevices':
        return {'list': await b.enumerateDevices(dig())};
      case 'selfCalibrate':
        await b.selfCalibrate(dig());
        return null;
      case 'correctionSummary':
        return (await b.correctionSummary(path())).toJson();
      case 'collidingFiles':
        return {'list': await b.collidingFiles(meas())};
      case 'clearSession':
        await b.clearSession(meas());
        return null;
      case 'startMeasurement':
        return {'path': await b.startMeasurement(AppSettings.fromJson(jMap(a['settings'])))};
      case 'stopMeasurement':
        await b.stopMeasurement();
        return null;
      case 'measuring':
        return {'value': b.measuring};
      case 'sessionSummary':
        return (await b.sessionSummary(path())).toJson();
      case 'readRecord':
        return (await b.readRecord(
          path(),
          jInt(a['group'], 1),
          jInt(a['record'], 1),
          maxPoints: jInt(a['maxPoints'], 5000),
        )).toJson();
      case 'recordSpectrum':
        return (await b.recordSpectrum(
          path(),
          jInt(a['group'], 1),
          jInt(a['record'], 1),
          window: enumByName(WindowType.values, a['window'], WindowType.hann),
          maxPoints: jInt(a['maxPoints'], 8192),
        )).toJson();
      case 'octaveStart':
        return (await b.octaveStart(oct())).toJson();
      case 'octaveRestart':
        return (await b.octaveRestart(oct())).toJson();
      case 'octaveStatus':
        return (await b.octaveStatus()).toJson();
      case 'octaveEval':
        return {'text': await b.octaveEval(jString(a['code']))};
      case 'octaveInstallPackage':
        await b.octaveInstallPackage(path());
        return null;
      case 'algorithms':
        return {
          'list': [for (final x in await b.algorithms()) x.toJson()],
        };
      case 'algorithmInfo':
        return (await b.algorithmInfo(jString(a['id']))).toJson();
      case 'processRecords':
        await b.processRecords(
          path(),
          ProcessingSetup.fromJson(jMap(a['setup'])),
          group: jInt(a['group'], 1),
          records: jIntList(a['records']),
        );
        return null;
      case 'stopProcessing':
        await b.stopProcessing();
        return null;
      case 'resultsInfo':
        return (await b.resultsInfo(path(), algorithm: jString(a['algorithm']))).toJson();
      case 'results':
        return (await b.results(path(), jString(a['algorithm']), view())).toJson();
      case 'resultData':
        return (await b.resultData(path(), jString(a['algorithm']), view())).toJson();
      case 'findCoherent':
        final r = await b.findCoherent(
          jDouble(a['f0']),
          jDouble(a['tMin']),
          jDouble(a['tMax']),
          jMap(a['rate']),
          jDouble(a['maxErr']),
          jDouble(a['timeout']),
        );
        return {'fs': r.fs, 'n': r.n, 'err': jNum(r.err)};
    }
    throw ArgumentError('Unknown method "$method"');
  }
}

/// HTTP + WebSocket server exposing a [TwmBackend] to remote clients
/// (web UI, other applications - successor of the TWM named pipe server).
///
/// * `POST /api/<method>` with JSON args -> `{"result": ...}` or `{"error": "..."}`
/// * `GET /events` WebSocket stream of [BackendEvent] JSON messages
/// * other GET requests serve static files from [webRoot] (built web UI)
class TwmServer {
  final TwmBackend backend;
  final String? webRoot;
  final String? token;
  final void Function(String)? log;

  HttpServer? _server;
  final _sockets = <WebSocket>{};
  StreamSubscription<BackendEvent>? _sub;

  TwmServer(this.backend, {this.webRoot, this.token, this.log});

  bool get running => _server != null;
  int? get port => _server?.port;
  int get clients => _sockets.length;

  Future<void> start({String host = '127.0.0.1', int port = 8080}) async {
    if (_server != null) return;
    final d = BackendDispatcher(backend);
    _server = await HttpServer.bind(host, port);
    log?.call('TWM server listening on http://$host:${_server!.port}');
    _sub = backend.events.listen((e) {
      final msg = jsonEncode(jSafe(e.toJson()));
      for (final s in _sockets.toList()) {
        try {
          s.add(msg);
        } catch (_) {}
      }
    });
    _server!.listen((req) async {
      try {
        await _handle(req, d);
      } catch (e) {
        try {
          req.response.statusCode = 500;
          req.response.write('$e');
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  bool _authorized(HttpRequest r) {
    if (token == null || token!.isEmpty) return true;
    return r.headers.value('authorization') == 'Bearer $token' || r.uri.queryParameters['token'] == token;
  }

  Future<void> _handle(HttpRequest req, BackendDispatcher d) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', 'content-type, authorization');
    if (req.method == 'OPTIONS') {
      await res.close();
      return;
    }
    final path = req.uri.path;
    if (path == '/events') {
      if (!_authorized(req)) {
        res.statusCode = 401;
        await res.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _sockets.add(ws);
      log?.call('client connected (${_sockets.length})');
      ws.listen(
        (_) {},
        onDone: () {
          _sockets.remove(ws);
          log?.call('client disconnected (${_sockets.length})');
        },
      );
      return;
    }
    if (path.startsWith('/api/') && req.method == 'POST') {
      if (!_authorized(req)) {
        res.statusCode = 401;
        await res.close();
        return;
      }
      final method = path.substring(5);
      final body = await utf8.decodeStream(req);
      final args = body.isEmpty ? <String, dynamic>{} : jMap(jsonDecode(body));
      res.headers.contentType = ContentType.json;
      try {
        final r = await d.call(method, args);
        res.write(jsonEncode({'result': jSafe(r)}));
      } catch (e) {
        res.write(jsonEncode({'error': '$e'}));
      }
      await res.close();
      return;
    }
    if (req.method == 'GET' && webRoot != null) {
      var rel = path == '/' ? 'index.html' : path.substring(1);
      var f = File(p.normalize(p.join(webRoot!, rel)));
      if (!p.isWithin(webRoot!, f.path) && f.path != p.join(webRoot!, 'index.html')) {
        res.statusCode = 403;
        await res.close();
        return;
      }
      if (!f.existsSync()) f = File(p.join(webRoot!, 'index.html'));
      if (f.existsSync()) {
        res.headers.contentType = _mime(f.path);
        await res.addStream(f.openRead());
        await res.close();
        return;
      }
    }
    res.statusCode = 404;
    await res.close();
  }

  static ContentType _mime(String f) => switch (p.extension(f)) {
    '.html' => ContentType.html,
    '.js' || '.mjs' => ContentType('application', 'javascript'),
    '.json' => ContentType.json,
    '.css' => ContentType('text', 'css'),
    '.png' => ContentType('image', 'png'),
    '.svg' => ContentType('image', 'svg+xml'),
    '.wasm' => ContentType('application', 'wasm'),
    '.ttf' || '.otf' => ContentType('font', 'ttf'),
    _ => ContentType.binary,
  };

  Future<void> stop() async {
    await _sub?.cancel();
    for (final s in _sockets.toList()) {
      await s.close();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
    log?.call('TWM server stopped');
  }
}
