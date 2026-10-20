import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Browser specific file transfer helpers.
class WebPlatform {
  static String? getSetting(String key) => web.window.localStorage.getItem(key);

  static void setSetting(String key, String value) => web.window.localStorage.setItem(key, value);

  /// Offers [bytes] as a file download.
  static void download(String name, Uint8List bytes, {String mime = 'application/octet-stream'}) {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
    final url = web.URL.createObjectURL(blob);
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = name;
    web.document.body?.append(a);
    a.click();
    a.remove();
    Timer(const Duration(seconds: 5), () => web.URL.revokeObjectURL(url));
  }

  /// Lets the user pick files from the computer; returns (name, bytes).
  static Future<List<(String, Uint8List)>> pickFiles({String accept = '', bool multiple = true}) {
    final c = Completer<List<(String, Uint8List)>>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept
      ..multiple = multiple;
    input.onchange = ((web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        c.complete(const []);
        return;
      }
      final out = <(String, Uint8List)>[];
      var pending = files.length;
      for (var i = 0; i < files.length; i++) {
        final f = files.item(i)!;
        f.arrayBuffer().toDart.then((b) {
          out.add((f.name, b.toDart.asUint8List()));
          if (--pending == 0) c.complete(out);
        });
      }
    }).toJS;
    input.click();
    return c.future;
  }
}
