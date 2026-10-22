import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/screens/correction_editor.dart';
import 'package:twm_app/screens/multiplexer_dialog.dart';
import 'package:twm_app/screens/processing_dialog.dart';
import 'package:twm_app/screens/sampling_assistant.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

final corr = '${AppPaths.resolve().home}/data/corrections';

/// Opens nested dialogs directly to catch build/layout errors.
void main() {
  final cases = <String, Future<void> Function(BuildContext)>{
    'multiplexer': (c) => showMultiplexerDialog(c, MultiplexerConfig()),
    'processing': (c) => showProcessingDialog(c, ProcessingSetup()),
    'sampling assistant': (c) => showSamplingAssistant(c, 10000, 1000),
    'transducer editor': (c) => showTransducerEditor(c, '$corr/transducers/shunt_100mA113/shunt_100mA113.info'),
    'transducer editor new': (c) => showTransducerEditor(c, ''),
    'digitizer editor': (c) => showDigitizerCorrectionEditor(c, '$corr/digitizer/HP3458A_session/HP3458A_2x.info'),
    'channel editor': (c) =>
        showDigitizerCorrectionEditor(c, '$corr/digitizer/HP3458A_session/chn1/HP3458A_chn1.info', channel: true),
    'csv editor': (c) => showCsvEditor(c, '$corr/transducers/shunt_100mA113/csv/tfer_gain.csv'),
    'csv editor template': (c) =>
        showCsvEditor(c, '/nonexistent/new.csv', template: CorrectionCatalog.transducerItems.first),
  };
  for (final e in cases.entries) {
    testWidgets('nested dialog ${e.key}', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('twm_ui');
      final backend = LocalBackend(
        AppPaths.resolve(settingsFile: '${tmp.path}/s.json'),
      );
      late AppState st;
      await tester.runAsync(() async => st = await AppState.create(backend));
      st.settings.digitizer.onClose = OnCloseAction.immediateReset;
      tester.view.physicalSize = const Size(1500, 950);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
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
      // let file reads (real IO) complete
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      // flush timers started inside the fake async zone (e.g. Octave start timeout)
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
      tester.view.reset();
    });
  }
}
