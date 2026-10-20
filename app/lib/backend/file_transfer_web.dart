import 'dart:typed_data';

import 'web/web_platform.dart';

bool get supported => true;
void download(String name, Uint8List bytes) => WebPlatform.download(name, bytes);
Future<List<(String, Uint8List)>> pick(String accept) => WebPlatform.pickFiles(accept: accept);
