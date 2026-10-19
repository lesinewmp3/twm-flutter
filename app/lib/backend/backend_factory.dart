import 'package:twm_model/twm_model.dart';

import 'backend_factory_stub.dart'
    if (dart.library.io) 'backend_factory_io.dart'
    if (dart.library.js_interop) 'backend_factory_web.dart'
    as impl;

/// Creates the backend: in-process on desktop, remote server on web
/// (or on desktop when [serverUrl] is given).
Future<TwmBackend> createBackend({String? serverUrl}) => impl.createBackend(serverUrl: serverUrl);

/// Whether this platform can run the in-process backend.
bool get canRunLocalBackend => impl.canRunLocalBackend;
