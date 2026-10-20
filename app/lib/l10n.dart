import 'dart:ui' as ui;

import 'l10n_ru.dart';

/// Minimal localization: English texts are the keys, Russian translations
/// are in [ruStrings]. Missing translations fall back to English.
class L10n {
  static bool ru = false;

  /// Applies setting 'auto' / 'ru' / 'en'.
  static void apply(String setting) {
    ru = switch (setting) {
      'ru' => true,
      'en' => false,
      _ => ui.PlatformDispatcher.instance.locale.languageCode == 'ru',
    };
  }
}

/// Translates [s] to the current UI language.
String tr(String s) => L10n.ru ? (ruStrings[s] ?? s) : s;

/// Translation with `{0}`, `{1}`... placeholders.
String trf(String s, List<Object?> args) {
  var r = tr(s);
  for (var i = 0; i < args.length; i++) {
    r = r.replaceAll('{$i}', '${args[i]}');
  }
  return r;
}
