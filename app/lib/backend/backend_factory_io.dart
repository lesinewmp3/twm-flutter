import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

import 'remote_backend.dart';

Future<TwmBackend> createBackend({String? serverUrl}) async {
  if (serverUrl != null && serverUrl.isNotEmpty) return RemoteBackend.connect(serverUrl);
  registerHardwareDrivers();
  return LocalBackend(AppPaths.resolve());
}

bool get canRunLocalBackend => true;
