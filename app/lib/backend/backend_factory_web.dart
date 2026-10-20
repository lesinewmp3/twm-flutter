import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

import 'bundled_assets.dart';
import 'remote_backend.dart';
import 'web/idb_store.dart';
import 'web/web_platform.dart';

/// Web: standalone browser backend (data in IndexedDB), or a TWM server
/// when the page is opened with `?server=http://host:port`.
Future<TwmBackend> createBackend({String? serverUrl}) async {
  final server = serverUrl ?? Uri.base.queryParameters['server'];
  if (server != null && server.isNotEmpty) return RemoteBackend.connect(server);
  final store = await IdbFileStore.open();
  await store.seed(await bundledCorrections());
  return BrowserBackend(
    store,
    loadSettingsText: () async => WebPlatform.getSetting('twm_settings'),
    saveSettingsText: (t) async => WebPlatform.setSetting('twm_settings', t),
  );
}

bool get canRunLocalBackend => true;
