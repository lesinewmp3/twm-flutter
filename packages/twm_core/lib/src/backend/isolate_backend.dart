import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:twm_model/twm_model.dart';

import '../drivers/drivers.dart';
import '../server/twm_server.dart';
import 'local_backend.dart';

/// Desktop backend running [LocalBackend] in a background isolate (the TWM
/// "measurement process"), so blocking instrument driver calls (VISA,
/// niScope, DAQmx FFI) and file processing never freeze the UI.
/// Communication uses the same JSON RPC as the network server.
class IsolateBackend extends RpcBackend {
  final SendPort _send;
  final ReceivePort _recv;
  final Isolate _isolate;
  final _pending = <int, Completer<Object?>>{};
  int _id = 0;

  IsolateBackend._(this._send, this._recv, this._isolate);

  static Future<IsolateBackend> spawn({String? home, String? settingsFile}) async {
    final recv = ReceivePort();
    final inbox = Completer<SendPort>();
    IsolateBackend? backend;
    final early = <dynamic>[];
    recv.listen((m) {
      if (!inbox.isCompleted && m is SendPort) {
        inbox.complete(m);
      } else if (backend != null) {
        backend._onMessage(m);
      } else {
        early.add(m);
      }
    });
    final iso = await Isolate.spawn(_main, [recv.sendPort, home, settingsFile], debugName: 'twm-backend');
    final b = IsolateBackend._(await inbox.future, recv, iso);
    backend = b;
    early.forEach(b._onMessage);
    return b;
  }

  void _onMessage(dynamic m) {
    if (m is! Map) return;
    final ev = m['event'];
    if (ev != null) {
      onEvent(jMap(ev));
      return;
    }
    final c = _pending.remove(m['id']);
    if (c == null) return;
    if (m['error'] != null) {
      c.completeError(Exception(m['error']));
    } else {
      c.complete(m['result']);
    }
  }

  @override
  Future<Object?> invoke(String method, [Json args = const {}]) {
    final id = ++_id;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send({'id': id, 'method': method, 'args': args});
    return c.future;
  }

  @override
  String get description => 'local';

  /// Starts ('start'), stops ('stop') or queries ('status') the network
  /// server hosted in the backend isolate.
  Future<Json> server(String action, {String host = '127.0.0.1', int port = 8080, String? token, String? web}) async =>
      jMap(await invoke('__server', {'action': action, 'host': host, 'port': port, 'token': token, 'web': web}));

  Future<void> dispose() async {
    try {
      await invoke('__dispose').timeout(const Duration(seconds: 5));
    } catch (_) {}
    _isolate.kill();
    _recv.close();
    await eventsController.close();
  }

  // ------------------------------------------------------- isolate side --

  static Future<void> _main(List<Object?> a) async {
    final out = a[0] as SendPort;
    registerHardwareDrivers();
    final backend = LocalBackend(AppPaths.resolve(home: a[1] as String?, settingsFile: a[2] as String?));
    final d = BackendDispatcher(backend);
    final inbox = ReceivePort();
    TwmServer? server;
    final serverLog = <String>[];
    // events and results are JSON values - re-encoding guarantees they are sendable
    backend.events.listen((e) => out.send({'event': jsonDecode(jsonEncode(e.toJson()))}));
    inbox.listen((m) async {
      if (m is! Map) return;
      final id = m['id'];
      final method = m['method'] as String;
      final args = jMap(m['args']);
      try {
        Object? r;
        switch (method) {
          case '__dispose':
            await server?.stop();
            await backend.dispose();
          case '__server':
            if (args['action'] == 'start') {
              await server?.stop();
              final token = args['token'] as String?;
              final web = args['web'] as String?;
              server = TwmServer(
                backend,
                token: token == null || token.isEmpty ? null : token,
                webRoot: web == null || web.isEmpty ? null : web,
                log: (l) => serverLog.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $l'),
              );
              await server!.start(host: args['host'] as String, port: args['port'] as int);
            } else if (args['action'] == 'stop') {
              await server?.stop();
              server = null;
            }
            r = {
              'running': server?.running ?? false,
              'port': server?.port,
              'clients': server?.clients ?? 0,
              'log': serverLog.length > 200 ? serverLog.sublist(serverLog.length - 200) : serverLog,
            };
          default:
            r = await d.call(method, args);
        }
        out.send({'id': id, 'result': jsonDecode(jsonEncode(r))});
      } catch (e) {
        out.send({'id': id, 'error': '$e'});
      }
    });
    out.send(inbox.sendPort);
  }
}
