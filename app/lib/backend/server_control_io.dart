import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

import 'server_control.dart';

bool get canHostServer => true;

final _instances = <TwmBackend, _IoServer>{};

ServerControl serverControlFor(TwmBackend backend) => _instances.putIfAbsent(backend, () => _IoServer(backend));

class _IoServer implements ServerControl {
  final TwmBackend backend;
  TwmServer? _s;
  @override
  final List<String> log = [];
  _IoServer(this.backend);

  @override
  bool get running => _s?.running ?? false;
  @override
  int? get port => _s?.port;
  @override
  int get clients => _s?.clients ?? 0;

  @override
  Future<void> start({required String host, required int port, String? token, String? webRoot}) async {
    await stop();
    _s = TwmServer(
      backend,
      token: token == null || token.isEmpty ? null : token,
      webRoot: webRoot == null || webRoot.isEmpty ? null : webRoot,
      log: (m) => log.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $m'),
    );
    await _s!.start(host: host, port: port);
  }

  @override
  Future<void> stop() async {
    await _s?.stop();
    _s = null;
  }
}
