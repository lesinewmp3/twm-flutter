import 'package:twm_model/twm_model.dart';

import 'server_control.dart';

bool canHostServer(TwmBackend backend) => false;

ServerControl serverControlFor(TwmBackend backend) =>
    throw UnsupportedError('Server can be hosted only by the desktop application.');
