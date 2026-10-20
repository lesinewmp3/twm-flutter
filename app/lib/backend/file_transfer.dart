import 'dart:typed_data';

import 'file_transfer_stub.dart' if (dart.library.js_interop) 'file_transfer_web.dart' as impl;

/// Upload/download of files between the user's computer and the browser
/// storage (web version only).
bool get fileTransferSupported => impl.supported;

void downloadFile(String name, Uint8List bytes) => impl.download(name, bytes);

Future<List<(String, Uint8List)>> pickFiles({String accept = ''}) => impl.pick(accept);
