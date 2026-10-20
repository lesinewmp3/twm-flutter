import 'dart:typed_data';

bool get supported => false;
void download(String name, Uint8List bytes) => throw UnsupportedError('download');
Future<List<(String, Uint8List)>> pick(String accept) async => const [];
