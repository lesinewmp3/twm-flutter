import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_core/twm_core.dart';

void main() {
  testWidgets('main screen builds with local backend', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_ui');
    final backend = LocalBackend(
      AppPaths.resolve(home: '/home/e/papka_dlya_claude/twm_flutter', settingsFile: '${tmp.path}/s.json'),
    );
    late AppState st;
    await tester.runAsync(() async => st = await AppState.create(backend));
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: st,
          child: MainScreen(onToggleTheme: () {}),
        ),
      ),
    );
    expect(find.text('START'), findsOneWidget);
    expect(find.text('SETUP MEASUREMENT'), findsOneWidget);
    expect(find.text('QWTB results'), findsOneWidget);
    await tester.tap(find.text('Live waveforms'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No data yet'), findsOneWidget);
    tester.view.reset();
  });
}
