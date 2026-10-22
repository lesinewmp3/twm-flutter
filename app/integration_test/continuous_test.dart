// Continuous measurement ("Continuous until STOP") in the real Linux app, as
// it is used to watch a UPS: records stored and processed while the
// acquisition runs, the monitor, the on-line analysis with the transfer
// analysis, page changes. Checks the record rate (no dead time), the monitor
// frames, the processing queue, the error log; saves pictures of the window
// to --dart-define=SHOTS.
//
//   flutter drive -d linux --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/continuous_test.dart --dart-define=SHOTS=/tmp/shots
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/screens/main_screen.dart';
import 'package:twm_app/state/app_state.dart';
import 'package:twm_app/theme.dart';
import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

final home = AppPaths.resolve().home;
const shotsDir = String.fromEnvironment('SHOTS');
const seconds = int.fromEnvironment('SECONDS', defaultValue: 60);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final report = <String, Object>{};

  testWidgets('continuous', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('twm_cont');
    final backend = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/settings.json');
    final st = await AppState.create(backend);
    L10n.apply('ru');
    final shotKey = GlobalKey();
    var shotNo = 0;
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: TwmTheme.light(),
          home: AppScope(state: st, child: MainScreen(onToggleTheme: () {})),
        ),
      ),
    );
    Future<void> settle([int ms = 400]) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> shot(String name) async {
      await settle(200);
      if (shotsDir.isEmpty) return;
      final ro = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File('$shotsDir/${(++shotNo).toString().padLeft(2, '0')}_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    }

    Future<void> click(Finder f) async {
      await tester.ensureVisible(f);
      await settle(150);
      await tester.tap(f, kind: PointerDeviceKind.mouse);
      await settle();
    }

    Future<bool> until(bool Function() cond, {Duration timeout = const Duration(seconds: 60)}) async {
      final end = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(end)) {
        if (cond()) return true;
        await tester.pump(const Duration(milliseconds: 16));
      }
      return cond();
    }

    // the records and monitor frames as the app gets them
    final stored = <int>[], frames = <int>[];
    final sw = Stopwatch()..start();
    var processed = 0, procErrors = <String>[];
    final sub = backend.events.listen((e) {
      if (e is RecordStoredEvent) stored.add(sw.elapsedMilliseconds);
      if (e is LiveEvent) frames.add(sw.elapsedMilliseconds);
      if (e is ProcessingEvent && !e.busy) {
        if (e.error.isEmpty) {
          processed++;
        } else {
          procErrors.add('${e.record}: ${e.error}');
        }
      }
    });

    void setup({required double fs, required int n, required ExecutionMode exec, SimEvent? event}) {
      st.update((s) {
        s.digitizer
          ..type = DigitizerType.simulated
          ..onClose = OnCloseAction.immediateReset;
        s.digitizer.simulated
          ..maxFs = 1e8
          ..realtimeFactor = 1;
        for (final c in s.digitizer.simulated.channels) {
          c.noiseRms = 0.002; // a live trace, as from a real converter
          c.event = event;
        }
        s.measurement
          ..folder = '${tmp.path}/m'
          ..nameBase = 'ups'
          ..fs = fs
          ..samplesCount = n
          ..continuous = true
          ..saveRecords = true
          ..processingEnabled = true
          ..processing.algorithmId = 'TWM-PSFE'
          ..processing.execution = exec;
        s.online
          ..monitorWindowMs = 80
          ..transferAnalysis = event != null;
      });
    }

    Future<void> pressStart() async {
      await click(find.text('Старт').first);
      if (find.text('Удалить и начать').evaluate().isNotEmpty) await click(find.text('Удалить и начать'));
    }

    Future<void> stopAndDrain() async {
      if (st.measuring) await click(find.text('Стоп').first);
      expect(await until(() => !st.measuring, timeout: const Duration(seconds: 20)), isTrue, reason: 'stopped');
      expect(
        await until(() => !st.processing && processed >= stored.length, timeout: const Duration(minutes: 5)),
        isTrue,
        reason: 'processing queue drained: $processed of ${stored.length}',
      );
      await settle(800);
    }

    // ---- 1: single-core processing in continuous mode: the start check warns
    setup(fs: 100000, n: 100000, exec: ExecutionMode.singleCore);
    await pressStart();
    expect(await until(() => find.textContaining('Всё равно начать?').evaluate().isNotEmpty), isTrue);
    expect(find.textContaining('Последовательная обработка останавливает съёмку'), findsOneWidget);
    await shot('single_core_warning');
    await click(find.text('Отмена').last);
    expect(st.measuring, isFalse);

    // ---- 2: parallel record processing, 1 s records, the monitor, page changes
    setup(fs: 100000, n: 100000, exec: ExecutionMode.parallelRecords);
    await pressStart();
    expect(await until(() => st.measuring), isTrue, reason: 'started without a warning');
    stored.clear();
    frames.clear();
    final t0 = sw.elapsedMilliseconds;
    var results5s = false;
    const pages = ['Измерение', 'Онлайн-анализ', 'Результаты', 'Измерение'];
    for (var k = 0; k < seconds ~/ 10; k++) {
      await settle(10000);
      if (k < pages.length) {
        await click(find.text(pages[k]).first);
        await shot('parallel_${k}_${pages[k]}');
        if (pages[k] == 'Результаты') {
          await settle(5000);
          await shot('parallel_${k}_results_after_5s');
          results5s = find.text('Загрузка...').evaluate().isEmpty;
        }
      }
    }
    final span = (sw.elapsedMilliseconds - t0) / 1000;
    final recs = stored.length;
    final gaps = [for (var k = 1; k < frames.length; k++) frames[k] - frames[k - 1]]..sort();
    await click(find.text('Стоп').first);
    await settle(1500);
    await shot('parallel_stop_queue');
    await stopAndDrain();
    await click(find.text('Измерение').first);
    await shot('parallel_after_stop');
    await click(find.text('Результаты').first);
    await settle(3000);
    await shot('parallel_results_after_stop');
    report['parallel'] = {
      'seconds': span.toStringAsFixed(1),
      'records': recs,
      'records_per_s': (recs / span).toStringAsFixed(2),
      'monitor_fps': (frames.length / span).toStringAsFixed(1),
      'monitor_gap_max_ms': gaps.isEmpty ? -1 : gaps.last,
      'processed': processed,
      'results_page_loaded_within_5s': results5s,
      'status': st.status,
    };
    expect(recs / span, greaterThan(0.9), reason: 'no dead time: ${report['parallel']}');
    expect(gaps.last, lessThan(300), reason: 'monitor gaps: ${report['parallel']}');
    expect(procErrors, isEmpty);

    // ---- 3: 1 MSa/s, 1 s records with a 4 ms interruption: transfer analysis
    stored.clear();
    frames.clear();
    processed = 0;
    setup(
      fs: 1e6,
      n: 1000000,
      exec: ExecutionMode.parallelRecords,
      event: SimEvent(start: 0.4, duration: 0.004, level: 0),
    );
    st.update((s) => s.measurement.processingEnabled = false);
    await pressStart();
    expect(await until(() => st.measuring), isTrue);
    final t1 = sw.elapsedMilliseconds;
    await settle(5000);
    await click(find.text('Онлайн-анализ').first);
    await settle(10000);
    await shot('transfer_online');
    await click(find.text('Измерение').first);
    await settle(5000);
    await shot('transfer_monitor');
    final span3 = (sw.elapsedMilliseconds - t1) / 1000;
    final recs3 = stored.length;
    final gaps3 = [for (var k = 1; k < frames.length; k++) frames[k] - frames[k - 1]]..sort();
    double? q(String name) {
      for (final x in st.lastOnline?.quantities ?? const <OnlineQuantity>[]) {
        if (x.name == name) return x.value;
      }
      return null;
    }

    final dur = q('Event duration u1');
    await click(find.text('Стоп').first);
    expect(await until(() => !st.measuring, timeout: const Duration(seconds: 20)), isTrue);
    await settle(800);
    report['transfer'] = {
      'seconds': span3.toStringAsFixed(1),
      'records_per_s': (recs3 / span3).toStringAsFixed(2),
      'monitor_gap_max_ms': gaps3.isEmpty ? -1 : gaps3.last,
      'event_duration_ms': dur ?? 'none',
      'status': st.status,
    };
    expect(recs3 / span3, greaterThan(0.85), reason: 'no dead time at 1 MSa/s: ${report['transfer']}');
    expect(dur, isNotNull);
    expect(dur!, closeTo(4.0, 0.05));
    report['errors'] = st.errors.toList();
    expect(st.errors, isEmpty, reason: 'error log: ${st.errors}');
    await sub.cancel();
    await backend.dispose();
    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 20)));

  tearDownAll(() {
    // ignore: avoid_print
    print('CONTINUOUS REPORT $report');
  });
}
