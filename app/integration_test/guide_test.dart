// The manual test guide for the Linux app, step by step, with the Russian UI
// and mouse clicks exactly as a person does them. Every step checks the
// values the guide says the user must see and saves a picture of the app
// window (its own rendering only) to the folder given by --dart-define=SHOTS.
//
//   flutter drive -d linux --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/guide_test.dart --dart-define=SHOTS=/tmp/shots
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

final home = AppPaths.resolve().home;
const shotsDir = String.fromEnvironment('SHOTS');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final log = <String>[];

  testWidgets('guide', (tester) async {
    // typing goes through the test text input (the real keyboard is not used)
    binding.testTextInput.register();
    final tmp = Directory.systemTemp.createTempSync('twm_guide');
    final backend = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/settings.json');
    final st = await AppState.create(backend);
    st.settings.measurement.folder = '${tmp.path}/TWM measurements';
    L10n.apply('ru');
    final shotKey = GlobalKey();
    var shotNo = 0;

    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: TwmTheme.light(),
          home: AppScope(state: st, child: MainScreen(onToggleTheme: () {})),
        ),
      ),
    );

    Future<void> settle([int ms = 400]) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> shot(String name) async {
      await settle(300);
      if (shotsDir.isEmpty) return;
      final ro = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File('$shotsDir/${(++shotNo).toString().padLeft(2, '0')}_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    }

    Future<void> click(Finder f) async {
      // ensureVisible scrolls a dialog to the element, as the user does with the wheel
      await tester.ensureVisible(f);
      await settle(150);
      await tester.tap(f, kind: PointerDeviceKind.mouse);
      await settle();
    }

    Future<bool> until(bool Function() cond, {Duration timeout = const Duration(seconds: 60)}) async {
      final end = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(end)) {
        if (cond()) return true;
        await tester.pump(const Duration(milliseconds: 50));
      }
      return cond();
    }

    Finder field(String label, [int index = 0]) =>
        find.ancestor(of: find.text(label), matching: find.byType(TextField)).at(index);

    Future<void> type(Finder f, String text) async {
      await click(f);
      await tester.enterText(f, text);
      await settle(200);
    }

    // press Start; confirm overwriting the previous measurement if asked; wait for the end
    Future<void> start({bool waitDone = true}) async {
      // the end is the FinishedEvent of the backend (the start checks may
      // first wait for Octave, so "not measuring" alone is not the end)
      var finished = false;
      final sub = backend.events.listen((e) {
        if (e is FinishedEvent) finished = true;
      });
      await click(find.text('Старт').first);
      if (find.text('Всё равно начать?', findRichText: true).evaluate().isNotEmpty ||
          find.textContaining('Всё равно начать?').evaluate().isNotEmpty) {
        // start check warning (e.g. processing of too short records): go on
        await shot('start_check_warning');
        await click(find.text('Старт').last);
      }
      if (find.text('Удалить и начать').evaluate().isNotEmpty) {
        await shot('overwrite_dialog');
        await click(find.text('Удалить и начать'));
      }
      if (waitDone) {
        expect(await until(() => finished, timeout: const Duration(minutes: 3)), isTrue, reason: 'measurement finished');
        expect(await until(() => !st.processing && !st.measuring, timeout: const Duration(minutes: 3)), isTrue);
        await settle(600);
      } else {
        expect(await until(() => st.measuring, timeout: const Duration(seconds: 30)), isTrue, reason: 'measurement started');
      }
      await sub.cancel();
    }

    double on(String name) => st.lastOnline!.quantities.firstWhere((q) => q.name == name).value;
    void check(String what, double v, double expected, double tol) {
      log.add('$what: ${v.toStringAsPrecision(8)} (expected $expected)');
      expect(v, closeTo(expected, tol), reason: what);
    }

    // ---- step 1: defaults
    await shot('start_screen');
    await start();
    await shot('measurement_defaults');
    await click(find.text('Онлайн-анализ'));
    await shot('online_defaults');
    check('RMS u1', on('RMS u1'), 5.000245, 2e-5);
    check('f u1', on('f u1'), 50, 1e-4);
    check('THD u1', on('THD u1'), 0.98995, 2e-4);
    check('RMS u2', on('RMS u2'), 0.353836, 2e-6);
    check('THD u2', on('THD u2'), 4.0000, 2e-4);

    // ---- step 2: transducers (dummy divider ch1, dummy shunt ch2) -> power
    await click(find.byTooltip('Коррекции'));
    await shot('corrections_empty');
    Future<void> addTransducer(String folder) async {
      await click(find.text('Добавить строку'));
      await click(find.byTooltip('Обзор...').last);
      await shot('browser_$folder');
      // the browser opens in the transducers folder
      await click(find.text(folder));
      await click(find.text('dummy.info'));
      await shot('browser_selected_$folder');
      await click(find.text('Выбрать'));
    }

    await addTransducer('dummy.vd');
    await addTransducer('dummy.cs');
    await shot('corrections_two_rows');
    await click(find.text('OK').last);
    await start();
    await click(find.text('Онлайн-анализ'));
    await shot('online_power');
    check('P L1', on('P L1'), 1.732529, 1e-5);
    check('S L1', on('S L1'), 1.769267, 1e-5);
    check('PF L1', on('PF L1'), 0.979236, 1e-5);

    // ---- step 3: QWTB TWM-PWRTDI in Octave
    await click(find.text('Настройка'));
    await shot('setup_dialog');
    // below the visible part of the dialog: scroll down
    await click(find.text('Вычислять результаты', skipOffstage: false));
    await shot('setup_processing_section');
    await click(find.text('Настройка обработки', skipOffstage: false));
    // the list of algorithms comes from Octave (first start takes seconds)
    final t1 = DateTime.now();
    expect(
      await until(
        () => find.text('TWM-PSFE', skipOffstage: false).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 90),
      ),
      isTrue,
    );
    // the selected algorithm is scrolled into view (also on a low window)
    await settle(500);
    expect(find.text('TWM-PSFE'), findsOneWidget);
    log.add('algorithm list loaded in ${DateTime.now().difference(t1).inMilliseconds} ms');
    await shot('processing_dialog');
    final list = find.ancestor(of: find.text('TWM-PSFE'), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('TWM-PWRTDI'), 120, scrollable: list);
    await click(find.text('TWM-PWRTDI'));
    await settle(2500);
    await shot('processing_pwrtdi');
    await click(find.text('OK').last);
    await click(find.text('OK').last);
    await start();
    await click(find.text('Результаты'));
    await settle(2500);
    await shot('results_pwrtdi');
    final sess = st.resultsSession;
    final r = await backend.resultData(sess, 'TWM-PWRTDI', ResultViewConfig(resultId: -1));
    double q(String n) => r.channels.expand((c) => c).firstWhere((x) => x.name == n).value.first;
    check('QWTB P', q('P'), 1.7325294, 1e-6);
    check('QWTB PF', q('PF'), 0.9792355, 1e-6);

    // ---- step 4: PF 0.99 (u: only 50 Hz, i: only 50 Hz shifted by -0.1415 rad)
    await click(find.byTooltip('Дигитайзер'));
    await shot('digitizer_defaults');
    await click(find.byIcon(Icons.close).at(1)); // ch1: 150 Hz
    await click(find.byIcon(Icons.close).at(2)); // ch2: 250 Hz
    await type(field('φ', 1), '-0.1415');
    await shot('digitizer_pf');
    await click(find.text('OK').last);
    await start();
    await click(find.text('Онлайн-анализ'));
    await shot('online_pf099');
    check('PF L1 (0.99 demo)', on('PF L1'), 0.990006, 2e-6);
    await click(find.text('Результаты'));
    await settle(2500);
    await shot('results_pf099');

    // ---- step 5: THD 3 % (i: 0.5 + 150 Hz 0.012 + 250 Hz 0.009)
    await click(find.byTooltip('Дигитайзер'));
    await click(find.text('составляющая').at(1));
    await type(field('f', 2), '150');
    await type(field('A', 2), '0.012');
    await click(find.text('составляющая').at(1));
    await type(field('f', 3), '250');
    await type(field('A', 3), '0.009');
    await shot('digitizer_thd');
    await click(find.text('OK').last);
    await start();
    await click(find.text('Онлайн-анализ'));
    await shot('online_thd3');
    check('THD i1 (3 % demo)', on('THD i1'), 3.0000, 2e-4);

    // ---- step 6: overload (ch2 amplitude 1.5 V on the 1 V range)
    await click(find.byTooltip('Дигитайзер'));
    await type(field('A', 1), '1.5');
    await click(find.text('OK').last);
    await start();
    await shot('overload');
    expect(st.errors.join('\n'), contains('Overload'));
    expect(find.text('Ошибка'), findsOneWidget, reason: 'red status after a failed run');
    expect(find.byType(SnackBar), findsOneWidget, reason: 'error message pops up');
    log.add('overload: ${st.errors.last}');
    await click(find.byTooltip('Дигитайзер'));
    await type(field('A', 1), '0.5');
    await click(find.text('OK').last);

    // ---- step 7: 2 MSa/s with 120 kHz ripple on ch2
    await click(find.byTooltip('Дигитайзер'));
    await type(field('Макс. частота дискретизации'), '2000000');
    await click(find.text('составляющая').at(1));
    await type(field('f', 4), '120000');
    await type(field('A', 4), '0.05');
    await shot('digitizer_ripple');
    await click(find.text('OK').last);
    await click(find.text('Настройка'));
    await type(field('Частота дискретизации'), '2000000');
    await type(field('Число отсчётов'), '2000000');
    await shot('setup_2M');
    await click(find.text('OK').last);
    final t0 = DateTime.now();
    await start();
    log.add('2 MSa/s record + QWTB: ${DateTime.now().difference(t0).inMilliseconds} ms');
    await click(find.text('Измерение').first);
    await shot('measurement_ripple');
    final wf = st.lastWaveform!;
    final peak = wf.spectra[1].asMap().entries.where((e) => e.key * wf.df > 1000).reduce((a, b) => a.value > b.value ? a : b);
    check('ripple peak frequency [Hz]', peak.key * wf.df, 120000, 3 * wf.df);

    // ---- step 8: records viewer with the spectrum of the whole record
    await click(find.text('Записи'));
    await settle(2500);
    await shot('records_waveform');
    // zoom with the mouse wheel: the visible part is loaded at full resolution
    final plot = tester.getRect(find.byType(CustomPaint).last);
    for (var k = 0; k < 30; k++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: plot.center, scrollDelta: const Offset(0, -40), kind: PointerDeviceKind.mouse),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(1500);
    await shot('records_zoomed');
    await tester.tapAt(plot.center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(plot.center); // double click: whole record again
    await settle(800);
    await click(find.text('Спектр'));
    await settle(4000);
    await shot('records_spectrum');

    // ---- step 9: the settings that froze the app: 1 MSa/s, 1000 samples, continuous
    await click(find.text('Настройка'));
    await type(field('Частота дискретизации'), '1000000');
    await type(field('Число отсчётов'), '1000');
    await click(find.text('Непрерывно до СТОП (TPQA)'));
    await shot('setup_short_record_warning');
    expect(find.textContaining('меньше 5 периодов'), findsOneWidget);
    await click(find.text('OK').last);
    await start(waitDone: false);
    await settle(5000);
    await shot('continuous_running');
    expect(st.measuring, isTrue);
    final sw = Stopwatch()..start();
    await click(find.text('Стоп'));
    expect(await until(() => !st.measuring, timeout: const Duration(seconds: 5)), isTrue);
    log.add('stop: ${sw.elapsedMilliseconds} ms');
    await shot('continuous_stopped');

    await backend.dispose();
    tmp.deleteSync(recursive: true);
    // ignore: avoid_print
    print('GUIDE LOG\n${log.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
