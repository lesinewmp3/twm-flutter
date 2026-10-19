import 'package:twm_model/twm_model.dart';

import 'server_control_stub.dart' if (dart.library.io) 'server_control_io.dart' as impl;

/// Control of the embedded TWM server (desktop only).
abstract class ServerControl {
  bool get running;
  int? get port;
  int get clients;
  List<String> get log;
  Future<void> start({required String host, required int port, String? token, String? webRoot});
  Future<void> stop();
}

bool get canHostServer => impl.canHostServer;

ServerControl serverControlFor(TwmBackend backend) => impl.serverControlFor(backend);
