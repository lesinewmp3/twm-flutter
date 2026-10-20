import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/batch_dialog.dart';
import 'package:twm_app/screens/corrections_dialog.dart';
import 'package:twm_app/screens/digitizer_dialog.dart';
import 'package:twm_app/screens/fft_viewer.dart';
import 'package:twm_app/screens/measurement_dialog.dart';
import 'package:twm_app/screens/octave_dialog.dart';
import 'package:twm_app/screens/record_viewer.dart';
import 'package:twm_app/screens/server_dialog.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// Opens every top level dialog (both languages, both backends) to catch
/// build/layout errors.
void main() {
  final dialogs = <String, Future<void> Function(BuildContext)>{
    'corrections': showCorrectionsDialog,
    'digitizer': showDigitizerDialog,
    'server': showServerDialog,
    'measurement': showMeasurementDialog,
    'octave': showOctaveDialog,
    'batch': showBatchDialog,
    'record viewer': showRecordViewer,
    'fft': showFftViewer,
  };
  for (final lang in ['en', 'ru']) {
    for (final browser in [false, true]) {
      for (final e in dialogs.entries) {
        testWidgets('${e.key} ($lang, ${browser ? 'browser' : 'desktop'})', (tester) async {
          final tmp = Directory.systemTemp.createTempSync('twm_ui');
          final TwmBackend b = browser
              ? BrowserBackend(MemoryFileStore())
              : LocalBackend(AppPaths.resolve(home: '/home/e/papka_dlya_claude/twm_flutter', settingsFile: '${tmp.path}/s.json'));
          late AppState st;
          await tester.runAsync(() async => st = await AppState.create(b));
          st.settings.digitizer.onClose = OnCloseAction.immediateReset;
          L10n.apply(lang);
          tester.view.physicalSize = const Size(1500, 950);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            MaterialApp(
              theme: TwmTheme.light(),
              home: AppScope(
                state: st,
                child: Scaffold(
                  body: Builder(builder: (c) => TextButton(onPressed: () => e.value(c), child: const Text('open'))),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          for (var i = 0; i < 5; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
            await tester.pump();
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(minutes: 10));
          L10n.apply('en');
          tester.view.reset();
        });
      }
    }
  }
}
