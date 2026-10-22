import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

Future<AppState> _state(WidgetTester tester, TwmBackend b) async {
  late AppState st;
  await tester.runAsync(() async => st = await AppState.create(b));
  st.settings.digitizer.onClose = OnCloseAction.immediateReset;
  return st;
}

Future<void> _pump(WidgetTester tester, AppState st, {Size size = const Size(1500, 950)}) async {
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
}

void main() {
  tearDown(() => L10n.apply('en'));

  testWidgets('main screen - desktop backend', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_ui');
    final st = await _state(tester, LocalBackend(AppPaths.resolve(settingsFile: '${tmp.path}/s.json')));
    L10n.apply('en');
    await _pump(tester, st);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Measurement'), findsWidgets);
    expect(find.text('Console'), findsOneWidget); // Octave available
    expect(find.text('Files'), findsNothing);
    await tester.tap(find.text('Results'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.reset();
  });

  testWidgets('error log: bounded, new errors noticed also after clearing it', (tester) async {
    final st = await _state(tester, BrowserBackend(MemoryFileStore()));
    L10n.apply('en');
    await _pump(tester, st);
    Finder badge(String n) => find.descendant(of: find.byType(Badge), matching: find.text(n));
    for (var i = 0; i < 250; i++) {
      st.addError('error $i');
    }
    await tester.pump();
    expect(st.errors.length, AppState.maxErrors);
    expect(st.errors.last, endsWith('error 249'));
    expect(badge('250'), findsOneWidget);
    // open the log (seen), clear it, a new error is shown again
    await tester.tap(find.byType(Badge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(st.errors, isEmpty);
    st.addError('after clearing');
    await tester.pump();
    expect(badge('1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // toast
    expect(tester.takeException(), isNull);
    tester.view.reset();
  });

  testWidgets('main screen - browser backend in Russian, narrow layout', (tester) async {
    final st = await _state(tester, BrowserBackend(MemoryFileStore()));
    L10n.apply('ru');
    await _pump(tester, st, size: const Size(700, 900));
    expect(find.text('Старт'), findsOneWidget);
    expect(find.text('Файлы'), findsOneWidget);
    expect(find.text('Консоль'), findsNothing); // no Octave in browser
    await tester.tap(find.text('Файлы'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.reset();
  });
}
