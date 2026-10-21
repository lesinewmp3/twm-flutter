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

/// [trMessage] of every line of a multi-line backend text.
String trLines(String m) => L10n.ru ? m.split('\n').map(trMessage).join('\n') : m;

/// Messages coming from the backend (engine, drivers, Octave) are English;
/// the ones a user meets most are translated by pattern.
String trMessage(String m) {
  if (!L10n.ru) return m;
  for (final (re, ru) in _messagePatterns) {
    final x = re.firstMatch(m);
    if (x != null) {
      // groups may be messages themselves ("Processing record 2: <error>")
      return ru.replaceAllMapped(RegExp(r'\$(\d)'), (g) {
        final v = x.group(int.parse(g[1]!)) ?? '';
        if (v.length >= m.length) return v; // a whole-message group is not re-translated
        final t = trMessage(v);
        return t == v ? tr(v) : t; // e.g. a digitizer name
      });
    }
  }
  return m;
}

final _messagePatterns = <(RegExp, String)>[
  // wrappers first: their inner message is translated as a group
  (RegExp(r'^Processing record (\d+): (.*)$'), r'Обработка записи $1: $2'),
  (
    RegExp(r'^Overload \(clipped signal\) of channel\(s\) ([\d, ]+) - increase the range\.$'),
    r'Перегрузка (сигнал обрезан) в канале(ах) $1 — увеличьте диапазон.',
  ),
  (
    RegExp(r'^Warning: overload \(clipped signal\) of channel\(s\) ([\d, ]+)$'),
    r'Внимание: перегрузка (сигнал обрезан) в канале(ах) $1',
  ),
  (RegExp(r'^Correction file not found: (.*)$'), r'Файл коррекции не найден: $1'),
  (
    RegExp(r'^(.*nonconformant arguments.*)$'),
    r'Ошибка внутри алгоритма Octave: «$1». Чаще всего причина — слишком короткая запись '
        r'(меньше 5 периодов сети) или неподходящие параметры алгоритма.',
  ),
  (
    RegExp(r"Missing 'i' channel of phase #(\d+)"),
    r'Нет канала тока для фазы $1: алгоритму мощности нужны делитель и шунт с одинаковым индексом фазы в «Коррекциях».',
  ),
  (
    RegExp(r'Distance between the harmonics in spectrum must be at least (\d+) \(detected (\d+)\)'),
    r'Запись слишком короткая для этого алгоритма: между гармониками в спектре нужно не меньше $1 бинов (сейчас $2). '
        r'Увеличьте длину записи (не меньше $1 периодов основной частоты).',
  ),
  (
    RegExp(r'^Cannot start "([^"]*)": (.*?)\. Check the GNU Octave/Matlab path.*$'),
    r'Не удаётся запустить «$1»: $2. Проверьте путь к GNU Octave/Matlab в окне «Octave / Matlab»',
  ),
  (RegExp(r'^Digitizing record (\d+)(/\d+)?\.\.\.$'), r'Оцифровка записи $1$2...'),
  (
    RegExp(r'^Simulated digitizer, (\d+) bit, (\d+) channel\(s\)\.$'),
    r'Симулятор дигитайзера, $1 бит, каналов: $2.',
  ),
  (
    RegExp(r'^#(\d+) (.*): range (\S+) V, (\d+) harmonic\(s\), noise (\S+) V rms$'),
    r'#$1 $2: диапазон $3 В, составляющих: $4, шум $5 В СКЗ',
  ),
  (
    RegExp(r'^Driver for "(.*)" is not available in this build\.$'),
    r'Драйвер «$1» в этой сборке недоступен.',
  ),
  (RegExp(r'^Driver not verified on real instruments\.$'), 'Драйвер не проверен на реальных приборах.'),
  (RegExp(r'^Processing record (\d+)\.\.\.$'), r'Обработка записи $1...'),
  (RegExp(r'^Initializing digitizer\.\.\.$'), 'Инициализация дигитайзера...'),
  (RegExp(r'^Configuring digitizer\.\.\.$'), 'Настройка дигитайзера...'),
  (RegExp(r'^Pre-record delay\.\.\.$'), 'Пауза перед записью...'),
  (RegExp(r'^Starting\.\.\.$'), 'Запуск...'),
  (RegExp(r'^Stopping\.\.\.$'), 'Остановка...'),
  (RegExp(r'^Done$'), 'Готово'),
  (RegExp(r'^Stopped$'), 'Остановлено'),
  (RegExp(r'^Processing done$'), 'Обработка завершена'),
  (RegExp(r'^Processing stopped$'), 'Обработка остановлена'),
  (RegExp(r'^Error: (.*)$'), r'Ошибка: $1'),
];
