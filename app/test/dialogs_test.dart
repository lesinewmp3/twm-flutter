import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// Opens every dialog of the main window to catch layout/build errors.
void main() {
  late AppState st;
  setUp(() async {});

  Future<void> pumpMain(WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_ui');
    final backend = LocalBackend(
      AppPaths.resolve(home: '/home/e/papka_dlya_claude/twm_flutter', settingsFile: '${tmp.path}/s.json'),
    );
    await tester.runAsync(() async => st = await AppState.create(backend));
    // no delayed-reset timers inside the fake async test zone
    st.settings.digitizer.onClose = OnCloseAction.immediateReset;
    tester.view.physicalSize = const Size(1500, 950);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: st,
          child: MainScreen(onToggleTheme: () {}),
        ),
      ),
    );
  }

  for (final b in [
    'HW Corrections',
    'Digitizer',
    'Server',
    'SETUP MEASUREMENT',
    'Octave/Matlab',
    'START QWTB CALC',
    'VIEW RECORD',
    'VIEW FFT',
  ]) {
    testWidgets('dialog $b opens', (tester) async {
      await pumpMain(tester);
      await tester.tap(find.text(b));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.reset();
    });
  }
}
