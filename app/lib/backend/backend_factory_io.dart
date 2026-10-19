import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

import 'remote_backend.dart';

/// Desktop: backend in a background isolate (or remote server).
Future<TwmBackend> createBackend({String? serverUrl}) async {
  if (serverUrl != null && serverUrl.isNotEmpty) return RemoteBackend.connect(serverUrl);
  return IsolateBackend.spawn();
}

bool get canRunLocalBackend => true;
