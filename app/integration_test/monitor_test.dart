// Live monitor in the real Linux app: frames per second, picture stability
// (trigger) and frame times while recording in real time.
//
//   flutter drive -d linux --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/monitor_test.dart --dart-define=SHOTS=/tmp/shots
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
const shotsDir = String.fromEnvironment('SHOTS');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('live monitor', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_mon');
    final backend = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/s.json');
    final st = await AppState.create(backend);
    L10n.apply('ru');
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: TwmTheme.light(),
          home: AppScope(state: st, child: MainScreen(onToggleTheme: () {})),
        ),
      ),
    );
    Future<void> live(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> shot(String name) async {
      if (shotsDir.isEmpty) return;
      final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await (await ro.toImage()).toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File('$shotsDir/monitor_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    }

    final report = <String, Object>{};
    await live(const Duration(seconds: 2)); // app start-up frames are not measured
    Future<void> scenario(String name, void Function(AppSettings s) cfg, Duration d, {double? amp, double? f}) async {
      st.update((s) {
        s.digitizer.onClose = OnCloseAction.immediateReset;
        s.measurement.folder = '${tmp.path}/m';
        cfg(s);
      });
      var frames = 0, synced = 0;
      var worstPhase = 0.0;
      final t0 = DateTime.now();
      void onLive() {
        final lv = st.live.value;
        if (lv == null) return;
        frames++;
        if (lv.triggered) {
          synced++;
          if (amp != null && f != null) {
            // first point must lie on the rising slope at time x0 after the crossing
            final expected = amp * math.sin(2 * math.pi * f * lv.x0);
            worstPhase = math.max(worstPhase, (lv.channels.first.first - expected).abs() / amp);
          }
        }
      }

      st.live.addListener(onLive);
      final timings = <FrameTiming>[];
      void onT(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(onT);
      await tester.tap(find.text('Старт').first);
      await live(const Duration(milliseconds: 300));
      if (find.text('Удалить и начать').evaluate().isNotEmpty) {
        await tester.tap(find.text('Удалить и начать'));
      }
      await live(d);
      await shot(name);
      if (st.measuring) {
        await tester.tap(find.text('Стоп').first);
        await live(const Duration(seconds: 1));
      }
      SchedulerBinding.instance.removeTimingsCallback(onT);
      st.live.removeListener(onLive);
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      double ms(Duration x) => x.inMicroseconds / 1000;
      final worst = timings.isEmpty ? 0.0 : timings.map((t) => ms(t.buildDuration) + ms(t.rasterDuration)).reduce(math.max);
      final slow = timings.where((t) => ms(t.buildDuration) + ms(t.rasterDuration) > 16.7).length;
      report[name] = {
        'live_fps': (frames / secs).toStringAsFixed(1),
        'synced': '$synced/$frames',
        if (amp != null) 'phase_err_rel': worstPhase.toStringAsExponential(1),
        'frames': timings.length,
        'worst_frame_ms': worst.toStringAsFixed(1),
        'frames_over_16ms': slow,
      };
    }

    // 1: default signal, 1 s records in real time
    await scenario('realtime_10k', (s) {
      s.digitizer.simulated.realtimeFactor = 1;
      s.measurement
        ..fs = 10000
        ..samplesCount = 10000
        ..recordsCount = 6
        ..continuous = false;
    }, const Duration(seconds: 5), amp: 7.0710678, f: 50);
    // 2: 2 MSa/s with 120 kHz ripple, 1 s records in real time
    await scenario('realtime_2M', (s) {
      s.digitizer.simulated
        ..realtimeFactor = 1
        ..maxFs = 2e6;
      s.digitizer.simulated.channels[1].harmonics.add(SimHarmonic(120000, 0.05, 0.3));
      s.measurement
        ..fs = 2e6
        ..samplesCount = 2000000
        ..recordsCount = 3;
    }, const Duration(seconds: 5));
    // 3: the "freeze" settings: 1 ms records, continuous
    await scenario('flood', (s) {
      s.measurement
        ..fs = 1e6
        ..samplesCount = 1000
        ..continuous = true
        ..saveRecords = false;
    }, const Duration(seconds: 4));

    // ignore: avoid_print
    print('MONITOR REPORT $report');
    await backend.dispose();
    tmp.deleteSync(recursive: true);
    final r1 = report['realtime_10k']! as Map;
    expect(double.parse(r1['live_fps'] as String), greaterThan(20), reason: '$r1');
    expect(double.parse(r1['phase_err_rel'] as String), lessThan(0.02), reason: 'picture must stand still: $r1');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
