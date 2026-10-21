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
import 'package:twm_app/screens/server_dialog.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

/// Russian UI: every visible text of every screen is checked for English
/// words that were not translated. Technical names (instruments, algorithm
/// ids, file names, units, instrument commands) are allowed.
const allowed = {
  // project, standards, software
  'TWM', 'TPQA', 'QWTB', 'TracePQM', 'Wattmeter', 'Octave', 'Matlab', 'GNU', 'CMI', 'INRIM', 'EMPIR', 'MIT',
  'GUF', 'RAW', 'CSV', 'JSON', 'INFO', 'Flutter', 'Linux', 'Windows', 'Dart', 'octprog', 'qwtb', 'multicore',
  'parcellfun', 'parfor', 'pkg', 'forge', 'TPQA-like',
  // instruments, buses, drivers
  'VISA', 'GPIB', 'PXI', 'PXI1Slot2', 'niScope', 'NI-SCOPE', 'DAQmx', 'cDAQ', 'cDAQ1Mod1', 'Keysight', 'Agilent',
  'Fluke', 'HP', 'DSO', 'AWG', 'ADS127L21', 'TClk', 'NI-TClk', 'ALSA', 'SINT', 'DINT', 'MASTER', 'SLAVE', 'TIMER',
  'EXT', 'DCV', 'DSDC', 'DSAC', 'ACAL', 'FLEXRES', 'PFI', 'PLL', 'USB', 'ASRL1', 'INSTR', 'TCPIP', 'SELF-CAL',
  'default', 'plughw', 'hw', 'sysdefault', 'pulse', 'pipewire', 'Simulated', 'Hanning', 'Hamming', 'Blackman',
  'Blackman-Harris', 'flattop', 'Monte', 'Carlo',
  // units, quantities
  'Sa/s', 'Hz', 'kHz', 'MHz', 'rms', 'Vpk', 'smpl', 'rad', 'var', 'VA', 'deg', 'ppm', 'dBc', 'dBV',
  'RMS', 'THD', 'phi1', 'u_A',
  // Octave packages, files, keys, instrument names
  'optim', 'signal', 'statistics', 'octave-cli', 'PATH', 'dummy', 'Shift', 'DIFF', 'Flat', 'HP/Keysight',
  'parcellfun/parfor', 'octprog/qwtb', 'corrections/transducers', 'Normal', 'open', 'Octave/Matlab',
};

final _word = RegExp(r"[A-Za-z][A-Za-z_\-/]{3,}");

List<String> _untranslated(WidgetTester tester) {
  final out = <String>{};
  for (final e in find.byType(Text, skipOffstage: false).evaluate()) {
    final w = e.widget as Text;
    final s = w.data ?? w.textSpan?.toPlainText() ?? '';
    if (s.isEmpty) continue;
    // paths, file names, numbers with units, algorithm ids are data, not UI text
    if (s.contains('/') && !s.contains(' ')) continue;
    if (RegExp(r'^(TWM|alg|SP|PSFE|FPNLSF|MFSF|WFFT|SFDR|ThreePSF|PSFE)[\w\-]*$').hasMatch(s)) continue;
    // channel names come from the instruments (data), %id% style variables
    if (s.startsWith('#')) continue;
    for (final m in _word.allMatches(s.replaceAll(RegExp(r'%\w+%'), ''))) {
      var word = m[0]!;
      while (word.endsWith('-') || word.endsWith('/')) {
        word = word.substring(0, word.length - 1);
      }
      if (allowed.contains(word) || word.contains('_') || word.length < 4) continue;
      if (word.startsWith('TWM-') || word.contains('.info') || word.contains('.csv') || word.contains('.mat')) continue;
      out.add(s.length > 90 ? '${s.substring(0, 90)}...' : s);
      break;
    }
  }
  return out.toList()..sort();
}

void main() {
  final found = <String, List<String>>{};

  Future<AppState> state(WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_l10n');
    late AppState st;
    await tester.runAsync(() async {
      st = await AppState.create(
        LocalBackend(AppPaths.resolve(home: '/home/e/papka_dlya_claude/twm_flutter', settingsFile: '${tmp.path}/s.json')),
      );
    });
    st.settings.digitizer.onClose = OnCloseAction.immediateReset;
    return st;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pumpApp(WidgetTester tester, AppState st, Widget home) async {
    L10n.apply('ru');
    tester.view.physicalSize = const Size(1500, 950);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(theme: TwmTheme.light(), home: AppScope(state: st, child: home)));
  }

  final dialogs = <String, Future<Object?> Function(BuildContext)>{
    'Коррекции': showCorrectionsDialog,
    'Сервер': showServerDialog,
    'Настройка измерения': showMeasurementDialog,
    'Octave': showOctaveDialog,
    'Пакетная обработка': showBatchDialog,
    'Просмотр записей': showRecordViewer,
    'Спектр алгоритма': showFftViewer,
    'Настройка обработки': (c) => showProcessingDialog(c, ProcessingSetup()),
  };
  for (final e in dialogs.entries) {
    testWidgets('dialog ${e.key}', (tester) async {
      final st = await state(tester);
      await pumpApp(
        tester,
        st,
        Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => e.value(c), child: const Text('open')))),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      found['dialog ${e.key}'] = _untranslated(tester);
      expect(found['dialog ${e.key}'], isEmpty, reason: 'untranslated texts');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    });
  }

  for (final type in DigitizerType.values) {
    testWidgets('digitizer page ${type.name}', (tester) async {
      final st = await state(tester);
      st.settings.digitizer.type = type;
      await pumpApp(
        tester,
        st,
        Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showDigitizerDialog(c), child: const Text('open')))),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      found['digitizer ${type.name}'] = _untranslated(tester);
      expect(found['digitizer ${type.name}'], isEmpty, reason: 'untranslated texts');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    });
  }

  testWidgets('dialogs with filled settings', (tester) async {
    final st = await state(tester);
    const root = '/home/e/papka_dlya_claude/twm_flutter/data/corrections/transducers';
    st.settings.corrections.transducers = [
      TransducerConfig(path: r'dummy.vd\dummy.info', highChannel: 1, nominalRatio: 1),
      TransducerConfig(path: r'dummy.cs\dummy.info', type: TransducerType.shunt, highChannel: 2, nominalRatio: 1),
    ];
    st.settings.corrections.transducersRoot = root;
    st.settings.digitizer.simulated.channels.first.event = SimEvent();
    for (final (name, open) in <(String, Future<Object?> Function(BuildContext))>[
      ('corrections with transducers', showCorrectionsDialog),
      ('simulator with event', showDigitizerDialog),
    ]) {
      await pumpApp(
        tester,
        st,
        Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => open(c), child: const Text('open')))),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      found[name] = _untranslated(tester);
      expect(found[name], isEmpty, reason: 'untranslated texts');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    }
  });

  testWidgets('main screen pages with data', (tester) async {
    final st = await state(tester);
    // data as after a measurement
    st.lastWaveform = WaveformEvent(1, const ['Simulated ADC, channel 1', 'Simulated ADC, channel 2'], [
      [for (var i = 0; i < 100; i++) i.toDouble()],
      [for (var i = 0; i < 100; i++) -i.toDouble()],
    ], 1e-4, spectra: [List.filled(50, 1e-3), List.filled(50, 1e-3)], df: 10);
    st.settings.online.transferAnalysis = true;
    st.lastOnline = OnlineResult([
      const OnlineQuantity('RMS u1', 'V', 5),
      const OnlineQuantity('Event start u1', 'ms', 123.4),
      const OnlineQuantity('Event duration u1', 'ms', 3.7),
      const OnlineQuantity('Event depth u1', '%', 0),
      const OnlineQuantity('Phase jump u1', 'deg', 30),
    ], {'u1': [5.0, 0.1]}, 50);
    await pumpApp(tester, st, MainScreen(onToggleTheme: () {}));
    await settle(tester);
    for (final page in ['Измерение', 'Результаты', 'Онлайн-анализ', 'Записи', 'Консоль']) {
      await tester.tap(find.text(page).first);
      await settle(tester);
      found['page $page'] = _untranslated(tester);
      expect(found['page $page'], isEmpty, reason: 'untranslated texts');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });

  tearDownAll(() {
    L10n.apply('en');
    final bad = {for (final e in found.entries) if (e.value.isNotEmpty) e.key: e.value};
    for (final e in bad.entries) {
      // ignore: avoid_print
      print('UNTRANSLATED in ${e.key}:\n  ${e.value.join('\n  ')}');
    }
    // ignore: avoid_print
    print('screens checked: ${found.length}, with untranslated texts: ${bad.length}');
  });
}
