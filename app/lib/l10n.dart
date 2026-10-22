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

const _ruUnits = {
  'V': 'В',
  'mV': 'мВ',
  'A': 'А',
  'Hz': 'Гц',
  'kHz': 'кГц',
  'W': 'Вт',
  'var': 'вар',
  'VA': 'В·А',
  'rad': 'рад',
  'deg': '°',
  's': 'с',
  'ms': 'мс',
  'Vpk': 'В пик',
  'V rms': 'В СКЗ',
  's rms': 'с СКЗ',
  'Sa/s': 'отсч/с',
  'smpl': 'отсч',
  'V/A': 'В/А',
};

/// Unit symbol in the UI language (Russian documents use Cyrillic symbols).
String trUnit(String u) => L10n.ru ? (_ruUnits[u] ?? u) : u;

/// Name of an on-line quantity ("Event duration u1"): the words before the
/// channel tag are translated, the tag is kept.
String trQuantity(String name) {
  final i = name.lastIndexOf(' ');
  if (i < 0) return tr(name);
  return '${tr(name.substring(0, i))} ${name.substring(i + 1)}';
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
  // driver setup errors
  (
    RegExp(
      r'^Streaming mode needs each 3458A on its own GPIB controller \((.*)\); use the memory mode with a shared bus\.$',
    ),
    r'Потоковому режиму нужен отдельный контроллер GPIB для каждого 3458A ($1); при общей шине используйте режим памяти.',
  ),
  (
    RegExp(
      r'^Samples count (\d+) exceeds 3458A memory \((\d+) readings\); enable streaming mode or Option 001 memory\.$',
    ),
    r'Число отсчётов $1 больше памяти 3458A ($2): включите потоковый режим или память Option 001.',
  ),
  (
    RegExp(r'^Sampling period (\S+) us too short for aperture (\S+) us \(min (\S+) us\)\.$'),
    r'Период дискретизации $1 мкс слишком мал для апертуры $2 мкс (минимум $3 мкс).',
  ),
  (
    RegExp(r'^Overload of channel\(s\) ([\d, ]+) - check ranges\.$'),
    r'Перегрузка в канале(ах) $1 — проверьте диапазоны.',
  ),
  (
    RegExp(r'^Sampling rate (\S+) Sa/s out of range \(max (\S+)\)\.$'),
    r'Частота дискретизации $1 отсч/с вне допустимого диапазона (максимум $2).',
  ),
  (
    RegExp(r'^cDAQ sampling rate is fixed to (\S+) Sa/s in the digitizer configuration\.$'),
    r'Частота дискретизации cDAQ задана в настройках дигитайзера: $1 отсч/с.',
  ),
  (RegExp(r'^Sound card supports only rates (.*) Sa/s\.$'), r'Звуковая карта поддерживает только частоты $1 отсч/с.'),
  (
    RegExp(r'^DSO: (\d+) bit resolution not available \(max\. (\d+) bits for this series\)\.$'),
    r'DSO: разрядность $1 бит недоступна (у этой серии не больше $2 бит).',
  ),
  (
    RegExp(r'^(.*) \(the record holds less than 5 mains periods\)$'),
    r'$1 (в записи меньше 5 периодов сети — увеличьте длину записи)',
  ),
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
    RegExp(r'^Cannot start "([^"]*)": (.*?)\. Check the GNU Octave/Matlab path in the configuration\. On Ubuntu: (.*)$'),
    r'Не удаётся запустить «$1»: $2. Установите GNU Octave ($3) или укажите путь к нему в окне «Octave / Matlab»',
  ),
  (
    RegExp(r'^Cannot start "([^"]*)": (.*?)\. Check the GNU Octave/Matlab path.*$'),
    r'Не удаётся запустить «$1»: $2. Проверьте путь к GNU Octave/Matlab в окне «Octave / Matlab»',
  ),
  (RegExp(r'^Digitizing record (\d+)(/\d+)?\.\.\.$'), r'Оцифровка записи $1$2...'),
  (RegExp(r'^Simulated digitizer, (\d+) bit, (\d+) channel\(s\)\.$'), r'Симулятор дигитайзера, $1 бит, каналов: $2.'),
  (
    RegExp(r'^#(\d+) (.*): range (\S+) V, (\d+) harmonic\(s\), noise (\S+) V rms$'),
    r'#$1 $2: диапазон $3 В, составляющих: $4, шум $5 В СКЗ',
  ),
  (RegExp(r'^Driver for "(.*)" is not available in this build\.$'), r'Драйвер «$1» в этой сборке недоступен.'),
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
