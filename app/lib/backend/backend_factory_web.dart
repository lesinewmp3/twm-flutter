import 'package:twm_model/twm_model.dart';

import 'remote_backend.dart';

Future<TwmBackend> createBackend({String? serverUrl}) =>
    RemoteBackend.connect(serverUrl == null || serverUrl.isEmpty ? Uri.base.origin : serverUrl);

bool get canRunLocalBackend => false;
