// Long run of the real Linux app: continuous measurement in real time with
// the live monitor, the on-line analysis and page changes. The memory (RSS) of
// the process must not grow after the warm-up, the measurement must keep
// running.
//
//   flutter drive -d linux --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/soak_ui_test.dart --dart-define=MINUTES=30
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

final home = AppPaths.resolve().home;
const minutes = int.fromEnvironment('MINUTES', defaultValue: 3);

int rssMb() {
  final m = RegExp(r'VmRSS:\s+(\d+)').firstMatch(File('/proc/self/status').readAsStringSync());
  return m == null ? 0 : int.parse(m[1]!) ~/ 1024;
}

double mean(Iterable<int> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('UI soak', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_uisoak');
    final backend = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/s.json');
    final st = await AppState.create(backend);
    L10n.apply('ru');
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TwmTheme.light(),
        home: AppScope(
          state: st,
          child: MainScreen(onToggleTheme: () {}),
        ),
      ),
    );
    Future<void> live(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await live(const Duration(seconds: 2));
    st.update((s) {
      s.digitizer.onClose = OnCloseAction.immediateReset;
      s.digitizer.simulated.realtimeFactor = 1;
      s.measurement
        ..folder = '${tmp.path}/m'
        ..fs = 100000
        ..samplesCount = 20000
        ..continuous = true
        ..saveRecords = false
        ..processingEnabled = false;
      s.online.transferAnalysis = true;
    });
    await tester.tap(find.text('Старт').first);
    await live(const Duration(milliseconds: 500));
    if (find.text('Удалить и начать').evaluate().isNotEmpty) {
      await tester.tap(find.text('Удалить и начать'));
    }

    const pages = ['Измерение', 'Онлайн-анализ', 'Консоль', 'Измерение', 'Результаты', 'Записи'];
    final rss = <int>[];
    var stopped = 0, liveFrames = 0, lastRecord = 0;
    void onLive() => liveFrames++;
    st.live.addListener(onLive);
    final end = DateTime.now().add(const Duration(minutes: minutes));
    for (var k = 0; DateTime.now().isBefore(end); k++) {
      await live(const Duration(seconds: 10));
      if (!st.measuring) stopped++;
      rss.add(rssMb());
      // another page every 30 s
      if (k % 3 == 2) await tester.tap(find.text(pages[(k ~/ 3) % pages.length]).first);
      lastRecord = st.lastWaveform?.record ?? lastRecord;
    }
    st.live.removeListener(onLive);
    await tester.tap(find.text('Стоп').first);
    await live(const Duration(seconds: 1));
    await backend.dispose();
    tmp.deleteSync(recursive: true);

    // growth: last quarter against the second quarter (after the warm-up)
    final q = rss.length ~/ 4;
    final early = mean(rss.sublist(q, 2 * q)), late = mean(rss.sublist(rss.length - q));
    final report = {
      'minutes': minutes,
      'records': lastRecord,
      'live_frames_per_s': (liveFrames / (minutes * 60)).toStringAsFixed(1),
      'rss_mb_start': rss.first,
      'rss_mb_q2': early.toStringAsFixed(0),
      'rss_mb_last_q': late.toStringAsFixed(0),
      'rss_mb_max': rss.reduce((a, b) => a > b ? a : b),
      'stopped_samples': stopped,
      'rss_series': rss.join(' '),
    };
    // ignore: avoid_print
    print('UI SOAK REPORT $report');
    expect(stopped, 0, reason: 'measurement kept running');
    expect(lastRecord, greaterThan(minutes * 60 * 3), reason: 'records keep coming (5/s in real time)');
    expect(late - early, lessThan(40), reason: 'no memory growth: $report');
  }, timeout: const Timeout(Duration(minutes: minutes + 5)));
}
