import 'package:flutter/services.dart';

/// Example corrections shipped with the app (assets/corrections), keyed by
/// their path in the browser storage (/corrections/...).
Future<Map<String, Uint8List>> bundledCorrections() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final out = <String, Uint8List>{};
  for (final a in manifest.listAssets().where((a) => a.startsWith('assets/corrections/'))) {
    final d = await rootBundle.load(a);
    out['/${a.substring('assets/'.length)}'] = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }
  return out;
}
