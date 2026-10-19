import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:twm_model/twm_model.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// [TwmBackend] client of a remote TWM server (`twm_server`): JSON RPC over
/// HTTP POST and events over WebSocket. Used by the web UI and optionally by
/// desktop UI controlling a measurement PC over network.
class RemoteBackend extends RpcBackend {
  final Uri base;
  final String? token;
  WebSocketChannel? _ws;
  final _client = http.Client();
  bool _disposed = false;

  RemoteBackend._(this.base, this.token);

  static Future<RemoteBackend> connect(String url, {String? token}) async {
    final b = RemoteBackend._(Uri.parse(url), token);
    // verifies address and access token before opening the event channel
    try {
      b.measuringState = jBool(jMap(await b.invoke('measuring'))['value']);
    } catch (e) {
      b._client.close();
      throw Exception('Cannot connect to TWM server $url: $e');
    }
    b._connectEvents();
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
    ws.ready.catchError((Object e) => onEvent(StatusEvent('Event channel error: $e').toJson()));
    ws.stream.listen(
      (m) => onEvent(jMap(jsonDecode(m as String))),
      onDone: () {
        if (_disposed) return;
        onEvent(const StatusEvent('Connection to server lost - reconnecting...').toJson());
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (!_disposed) _connectEvents();
        });
      },
      onError: (_) {},
    );
  }

  @override
  Future<Object?> invoke(String method, [Json args = const {}]) async {
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

  @override
  String get description => 'server ${base.origin}';

  Future<void> dispose() async {
    _disposed = true;
    await _ws?.sink.close();
    _client.close();
    await eventsController.close();
  }
}
