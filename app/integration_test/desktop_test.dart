// End-to-end test of the Linux desktop app: real window, real backend
// isolate, simulated digitizer, GNU Octave. Measures the frame times while
// the app works hard. Run in profile mode (release speed):
//
//   flutter drive -d linux --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/desktop_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

const home = '/home/e/papka_dlya_claude/twm_flutter';

/// Frame build/raster times collected while [body] runs.
class FrameStats {
  final List<Duration> build = [], raster = [];
  void add(List<FrameTiming> t) {
    for (final f in t) {
      build.add(f.buildDuration);
      raster.add(f.rasterDuration);
    }
  }

  static double _ms(Duration d) => d.inMicroseconds / 1000;
  double worst(List<Duration> l) => l.isEmpty ? 0 : l.map(_ms).reduce((a, b) => a > b ? a : b);
  double p99(List<Duration> l) {
    if (l.isEmpty) return 0;
    final s = l.map(_ms).toList()..sort();
    return s[(s.length * 0.99).floor().clamp(0, s.length - 1)];
  }

  int slow(double ms) => [for (var i = 0; i < build.length; i++) _ms(build[i]) + _ms(raster[i]) > ms].where((x) => x).length;

  Map<String, Object> summary() => {
    'frames': build.length,
    'build_worst_ms': worst(build),
    'build_p99_ms': p99(build),
    'raster_worst_ms': worst(raster),
    'raster_p99_ms': p99(raster),
    'frames_over_33ms': slow(33),
    'frames_over_100ms': slow(100),
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final report = <String, Object>{};
  late Directory tmp;
  late IsolateBackend backend;
  late AppState st;

  Future<FrameStats> watch(Future<void> Function() body) async {
    final s = FrameStats();
    SchedulerBinding.instance.addTimingsCallback(s.add);
    try {
      await body();
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(s.add);
    }
    return s;
  }

  Future<void> live(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<bool> until(WidgetTester tester, bool Function() cond, Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (cond()) return true;
      await tester.pump(const Duration(milliseconds: 50));
    }
    return cond();
  }

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('twm_e2e');
    backend = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/settings.json');
    st = await AppState.create(backend);
    L10n.apply('en');
  });

  tearDownAll(() async {
    binding.reportData = report;
    // ignore: avoid_print
    print('E2E REPORT $report');
    await backend.dispose();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('desktop app under load', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TwmTheme.light(),
        home: AppScope(state: st, child: MainScreen(onToggleTheme: () {})),
      ),
    );
    // the first frames of the app (fonts, first layout) are not part of the scenarios
    final startup = await watch(() => live(tester, const Duration(seconds: 2)));
    report['startup'] = startup.summary();

    // --- 1: the settings that froze the app: 1 MSa/s, 1000 samples, continuous
    st.update((s) {
      s.digitizer.type = DigitizerType.simulated;
      s.digitizer.simulated
        ..realtimeFactor = 1
        ..maxFs = 1e8;
      s.measurement
        ..folder = '${tmp.path}/meas'
        ..nameBase = 'flood'
        ..fs = 1e6
        ..samplesCount = 1000
        ..continuous = true
        ..saveRecords = false
        ..processingEnabled = false;
    });
    var waveforms = 0;
    final sub = backend.events.listen((e) {
      if (e is WaveformEvent) waveforms++;
    });
    final flood = await watch(() async {
      await tester.tap(find.text('Start'));
      await live(tester, const Duration(seconds: 6));
    });
    expect(st.measuring, isTrue);
    final rec1 = st.lastWaveform?.record ?? 0;
    expect(rec1, greaterThan(1000), reason: 'records keep coming');
    expect(waveforms, inInclusiveRange(30, 80), reason: 'live data ~10/s');
    final sw = Stopwatch()..start();
    await tester.tap(find.text('Stop'));
    expect(await until(tester, () => !st.measuring, const Duration(seconds: 3)), isTrue, reason: 'stop works');
    report['flood'] = {...flood.summary(), 'records': rec1, 'live_updates': waveforms, 'stop_ms': sw.elapsedMilliseconds};
    await sub.cancel();

    // --- 2: 2 MSa/s, 3 records x 2M samples saved, QWTB TWM-PSFE in Octave per record
    st.update((s) {
      s.digitizer.simulated.realtimeFactor = 0;
      s.measurement
        ..nameBase = 'hf'
        ..fs = 2e6
        ..samplesCount = 2000000
        ..recordsCount = 3
        ..continuous = false
        ..saveRecords = true
        ..processingEnabled = true
        ..processing.algorithmId = 'TWM-PSFE';
    });
    final sw2 = Stopwatch()..start();
    final hf = await watch(() async {
      await tester.tap(find.text('Start'));
      await tester.pump(const Duration(milliseconds: 200));
      // a colliding-files confirmation would appear for an existing folder
      expect(await until(tester, () => !st.measuring && !st.processing, const Duration(minutes: 3)), isTrue);
    });
    report['hf_2M_qwtb'] = {...hf.summary(), 'total_s': sw2.elapsedMilliseconds / 1000};
    final session = st.resultsSession;
    expect(session, isNotEmpty);
    final info = await backend.resultsInfo(session, algorithm: 'TWM-PSFE');
    expect(info.exists, isTrue, reason: 'QWTB results stored');
    report['hf_results'] = 'algorithms ${info.algorithms}, channels ${info.channels}';

    // --- 3: record viewer with the spectrum of a 2M sample record
    final viewer = await watch(() async {
      await tester.tap(find.text('Records'));
      await live(tester, const Duration(seconds: 2));
      await tester.tap(find.text('Spectrum'));
      await live(tester, const Duration(seconds: 3));
    });
    report['viewer'] = viewer.summary();
    // mouse moving over the spectrum (hover cursor read-out)
    final chart = tester.getRect(find.byType(CustomPaint).last);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: chart.centerLeft);
    final hover = await watch(() async {
      for (var k = 0; k < 120; k++) {
        await mouse.moveTo(Offset(chart.left + chart.width * (0.1 + 0.8 * (k % 60) / 60), chart.center.dy));
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
    await mouse.removePointer();
    report['viewer_hover'] = hover.summary();

    // --- 4: results and on-line analysis pages (each switch measured)
    final pageKeys = <String>[];
    for (final p in ['Results', 'On-line analysis', 'Measurement', 'Results']) {
      final ps = await watch(() async {
        await tester.tap(find.text(p).first);
        await live(tester, const Duration(milliseconds: 1500));
      });
      final key = 'page ${p.toLowerCase()} ${pageKeys.length}';
      pageKeys.add(key);
      report[key] = ps.summary();
    }

    for (final k in ['flood', 'hf_2M_qwtb', 'viewer', 'viewer_hover', ...pageKeys]) {
      final m = report[k] as Map;
      expect(m['frames_over_100ms'] as int, lessThan(3), reason: '$k: UI freezes $m');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
