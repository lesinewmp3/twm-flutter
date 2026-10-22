import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/batch_dialog.dart';
import 'package:twm_app/screens/corrections_dialog.dart';
import 'package:twm_app/screens/digitizer_dialog.dart';
import 'package:twm_app/screens/fft_viewer.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/screens/measurement_dialog.dart';
import 'package:twm_app/screens/octave_dialog.dart';
import 'package:twm_app/screens/processing_dialog.dart';
import 'package:twm_app/screens/record_viewer.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// Laptop screens: the window is at most 90 % of the work area (1366x768 ->
/// about 1229x650 inside). Every page and dialog in Russian (the longer
/// texts) must lay out without overflow.
void main() {
  tearDown(() => L10n.apply('en'));

  Future<AppState> state(WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_small');
    late AppState st;
    await tester.runAsync(() async {
      st = await AppState.create(LocalBackend(AppPaths.resolve(settingsFile: '${tmp.path}/s.json')));
    });
    st.settings.digitizer.onClose = OnCloseAction.immediateReset;
    return st;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  for (final size in const [Size(1200, 650), Size(1024, 600)]) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('main screen pages $name', (tester) async {
      final st = await state(tester);
      st.lastWaveform = WaveformEvent(
        1,
        const ['Simulated ADC, channel 1', 'Simulated ADC, channel 2'],
        [
          [for (var i = 0; i < 100; i++) i.toDouble()],
          [for (var i = 0; i < 100; i++) -i.toDouble()],
        ],
        1e-4,
        spectra: [List.filled(50, 1e-3), List.filled(50, 1e-3)],
        df: 10,
      );
      st.settings.online.transferAnalysis = true;
      st.lastOnline = OnlineResult(
        [const OnlineQuantity('RMS u1', 'V', 5), const OnlineQuantity('Event duration u1', 'ms', 3.7)],
        {
          'u1': [5.0, 0.1],
        },
        50,
      );
      L10n.apply('ru');
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: TwmTheme.light(),
          home: AppScope(
            state: st,
            child: MainScreen(onToggleTheme: () {}),
          ),
        ),
      );
      await settle(tester);
      for (final page in ['Измерение', 'Результаты', 'Онлайн-анализ', 'Записи', 'Консоль']) {
        await tester.tap(find.text(page).first);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'page $page');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
      tester.view.reset();
    });

    testWidgets('error message does not cover the tool buttons $name', (tester) async {
      final st = await state(tester);
      L10n.apply('ru');
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(theme: TwmTheme.light(), home: AppScope(state: st, child: MainScreen(onToggleTheme: () {}))),
      );
      await settle(tester);
      st.addError('Overload (clipped signal) of channel(s) 2 - increase the range.');
      await settle(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      final bar = find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first;
      expect(tester.getRect(bar).left, greaterThan(92), reason: 'not over the navigation rail');
      // the digitizer button is still usable
      await tester.tap(find.byTooltip('Дигитайзер'));
      await settle(tester);
      expect(find.text('Настройка дигитайзера'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
      tester.view.reset();
    });

    final dialogs = <String, Future<Object?> Function(BuildContext)>{
      'corrections': showCorrectionsDialog,
      'digitizer': showDigitizerDialog,
      'measurement': showMeasurementDialog,
      'octave': showOctaveDialog,
      'batch': showBatchDialog,
      'record viewer': showRecordViewer,
      'fft': showFftViewer,
      'processing': (c) => showProcessingDialog(c, ProcessingSetup()),
    };
    for (final e in dialogs.entries) {
      testWidgets('dialog ${e.key} $name', (tester) async {
        final st = await state(tester);
        L10n.apply('ru');
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            theme: TwmTheme.light(),
            home: AppScope(
              state: st,
              child: Scaffold(
                body: Builder(
                  builder: (c) => TextButton(onPressed: () => e.value(c), child: const Text('open')),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 10));
        tester.view.reset();
      });
    }

    for (final type in DigitizerType.values) {
      testWidgets('digitizer page ${type.name} $name', (tester) async {
        final st = await state(tester);
        st.settings.digitizer.type = type;
        L10n.apply('ru');
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            theme: TwmTheme.light(),
            home: AppScope(
              state: st,
              child: Scaffold(
                body: Builder(
                  builder: (c) => TextButton(onPressed: () => showDigitizerDialog(c), child: const Text('open')),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 10));
        tester.view.reset();
      });
    }
  }
}
