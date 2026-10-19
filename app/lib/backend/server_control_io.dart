import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

import 'server_control.dart';

bool canHostServer(TwmBackend backend) => backend is IsolateBackend;

final _cache = Expando<_IsoServer>();

ServerControl serverControlFor(TwmBackend backend) => _cache[backend] ??= _IsoServer(backend as IsolateBackend);

/// Server hosted in the backend isolate.
class _IsoServer implements ServerControl {
  final IsolateBackend b;
  _IsoServer(this.b);

  Json _s = const {};

  @override
  bool get running => jBool(_s['running']);
  @override
  int? get port => _s['port'] == null ? null : jInt(_s['port']);
  @override
  int get clients => jInt(_s['clients']);
  @override
  List<String> get log => jStringList(_s['log']);

  @override
  Future<void> refresh() async => _s = await b.server('status');

  @override
  Future<void> start({required String host, required int port, String? token, String? webRoot}) async =>
      _s = await b.server('start', host: host, port: port, token: token, web: webRoot);

  @override
  Future<void> stop() async => _s = await b.server('stop');
}
