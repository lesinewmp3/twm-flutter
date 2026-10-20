import 'dart:io';

import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

import 'bundled_assets.dart';
import 'remote_backend.dart';

/// Desktop: backend in a background isolate (or remote server).
/// `TWM_BROWSER_MODE=1` runs the browser version backend (for testing the
/// web UI on desktop).
Future<TwmBackend> createBackend({String? serverUrl}) async {
  if (serverUrl != null && serverUrl.isNotEmpty) return RemoteBackend.connect(serverUrl);
  if (Platform.environment['TWM_BROWSER_MODE'] == '1') {
    final store = MemoryFileStore();
    for (final e in (await bundledCorrections()).entries) {
      await store.writeBytes(e.key, e.value);
    }
    return BrowserBackend(store);
  }
  return IsolateBackend.spawn();
}

bool get canRunLocalBackend => true;
