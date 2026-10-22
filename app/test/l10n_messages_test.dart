import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

void main() {
  tearDown(() => L10n.apply('en'));
  test('driver setup errors are translated (the real messages of the drivers)', () async {
    registerHardwareDrivers();
    Future<String> error(Future<void> Function() f) async {
      try {
        await f();
      } on DigitizerException catch (e) {
        return e.message;
      }
      fail('no error');
    }

    final dmm = DigitizerConfig(type: DigitizerType.hp3458a)
      ..hp3458a.channels = [DmmChannelConfig(visa: 'SIM::3458A::1'), DmmChannelConfig(visa: 'SIM::3458A::2')];
    final d = Hp3458aDigitizer(dmm);
    await d.initialize();
    final messages = [
      await error(
        () => d.setup(fs: 10000, samplesCount: 200000, trigger: TriggerConfig(), aperture: 1e-6, ranges: [1, 1]),
      ),
      await error(
        () => d.setup(fs: 50000, samplesCount: 100, trigger: TriggerConfig(), aperture: 100e-6, ranges: [1, 1]),
      ),
      await error(
        () => Hp3458aDigitizer(
          DigitizerConfig(type: DigitizerType.hp3458a)
            ..hp3458a.streaming = true
            ..hp3458a.channels = [
              DmmChannelConfig(visa: 'GPIB0::22::INSTR'),
              DmmChannelConfig(visa: 'GPIB0::23::INSTR'),
            ],
        ).initialize(),
      ),
    ];
    await d.close();
    final dso = KeysightDsoDigitizer(
      DigitizerConfig(type: DigitizerType.keysightDso)
        ..dso.visa = 'SIM::DSO::1'
        ..dso.bitResolution = '17',
    );
    await dso.initialize();
    messages.add(
      await error(() => dso.setup(fs: 1e6, samplesCount: 100, trigger: TriggerConfig(), aperture: 0, ranges: const [])),
    );
    await dso.close(resetToPreset: false);
    L10n.apply('ru');
    final ru = [for (final m in messages) trMessage(m)];
    expect(ru[0], startsWith('Число отсчётов 200000 больше памяти 3458A'), reason: messages[0]);
    expect(ru[1], startsWith('Период дискретизации 20'), reason: messages[1]);
    expect(ru[2], startsWith('Потоковому режиму нужен отдельный контроллер GPIB'), reason: messages[2]);
    expect(ru[3], 'DSO: разрядность 17 бит недоступна (у этой серии не больше 16 бит).', reason: messages[3]);
    expect(
      trMessage('Overload of channel(s) 1, 2 - check ranges.'),
      'Перегрузка в канале(ах) 1, 2 — проверьте диапазоны.',
    );
    // simulator: the real message, numbers without '.0'
    final sim = SimulatedDigitizer(DigitizerConfig()..simulated.maxFs = 1e6);
    await sim.initialize();
    final simMsg = await error(
      () => sim.setup(fs: 2e6, samplesCount: 100, trigger: TriggerConfig(), aperture: 0, ranges: const []),
    );
    expect(trMessage(simMsg), 'Частота дискретизации 2000000 отсч/с вне допустимого диапазона (максимум 1000000).');
  });

  test('backend messages are translated by pattern', () {
    L10n.apply('ru');
    expect(
      trMessage('Overload (clipped signal) of channel(s) 2 - increase the range.'),
      'Перегрузка (сигнал обрезан) в канале(ах) 2 — увеличьте диапазон.',
    );
    expect(trMessage('Digitizing record 3/10...'), 'Оцифровка записи 3/10...');
    expect(trMessage('Digitizing record 7...'), 'Оцифровка записи 7...');
    expect(
      trMessage(
        'Processing record 2: Cannot start "x": No such file. Check the GNU Octave/Matlab path or the bin folder.',
      ),
      'Обработка записи 2: Не удаётся запустить «x»: No such file. Проверьте путь к GNU Octave/Matlab в окне «Octave / Matlab»',
    );
    expect(trMessage('Done'), 'Готово');
    expect(
      trMessage('Processing record 1: Distance between the harmonics in spectrum must be at least 30 (detected 11)!'),
      startsWith(
        'Обработка записи 1: Запись слишком короткая для этого алгоритма: между гармониками в спектре нужно не меньше 30 бинов (сейчас 11).',
      ),
    );
    expect(trMessage('something else'), 'something else');
    expect(
      trMessage('Processing record 3: =: nonconformant arguments (op1 is 1x1, op2 is 1x0) [thd_wfft:120]'),
      startsWith('Обработка записи 3: Ошибка внутри алгоритма Octave: «=: nonconformant arguments'),
    );
    expect(
      trMessage("QWTB algorithm executer: Missing 'i' channel of phase #1!"),
      startsWith('Нет канала тока для фазы 1'),
    );
    L10n.apply('en');
    expect(trMessage('Done'), 'Done');
  });
}
