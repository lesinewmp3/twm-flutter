// Headless TWM server: measurement + processing backend for the web UI or
// for remote control by other applications.
//
// usage: dart run twm_core:twm_server [--host 0.0.0.0] [--port 8080]
//        [--web <folder with built web UI>] [--token <secret>]
import 'dart:io';

import 'package:twm_core/twm_core.dart';

Future<void> main(List<String> args) async {
  String opt(String name, String def) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  registerHardwareDrivers();
  final backend = LocalBackend(AppPaths.resolve());
  final web = opt('web', '');
  final token = opt('token', '');
  final server = TwmServer(backend, webRoot: web.isEmpty ? null : web, token: token.isEmpty ? null : token, log: print);
  await server.start(host: opt('host', '127.0.0.1'), port: int.parse(opt('port', '8080')));
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    await backend.dispose();
    exit(0);
  });
}
