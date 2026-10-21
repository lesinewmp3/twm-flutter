import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/l10n.dart';

void main() {
  tearDown(() => L10n.apply('en'));
  test('backend messages are translated by pattern', () {
    L10n.apply('ru');
    expect(
      trMessage('Overload (clipped signal) of channel(s) 2 - increase the range.'),
      'Перегрузка (сигнал обрезан) в канале(ах) 2 — увеличьте диапазон.',
    );
    expect(trMessage('Digitizing record 3/10...'), 'Оцифровка записи 3/10...');
    expect(trMessage('Digitizing record 7...'), 'Оцифровка записи 7...');
    expect(
      trMessage('Processing record 2: Cannot start "x": No such file. Check the GNU Octave/Matlab path or the bin folder.'),
      'Обработка записи 2: Не удаётся запустить «x»: No such file. Проверьте путь к GNU Octave/Matlab в окне «Octave / Matlab»',
    );
    expect(trMessage('Done'), 'Готово');
    expect(
      trMessage('Processing record 1: Distance between the harmonics in spectrum must be at least 30 (detected 11)!'),
      startsWith('Обработка записи 1: Запись слишком короткая для этого алгоритма: между гармониками в спектре нужно не меньше 30 бинов (сейчас 11).'),
    );
    expect(trMessage('something else'), 'something else');
    expect(
      trMessage('Processing record 3: =: nonconformant arguments (op1 is 1x1, op2 is 1x0) [thd_wfft:120]'),
      startsWith('Обработка записи 3: Ошибка внутри алгоритма Octave: «=: nonconformant arguments'),
    );
    expect(trMessage("QWTB algorithm executer: Missing 'i' channel of phase #1!"), startsWith('Нет канала тока для фазы 1'));
    L10n.apply('en');
    expect(trMessage('Done'), 'Done');
  });
}
