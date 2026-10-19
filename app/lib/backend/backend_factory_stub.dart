import 'package:twm_model/twm_model.dart';

Future<TwmBackend> createBackend({String? serverUrl}) =>
    throw UnsupportedError('No backend available on this platform.');

bool get canRunLocalBackend => false;
