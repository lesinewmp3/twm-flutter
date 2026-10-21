// Stress test of the desktop pipeline: backend isolate + measurement engine
// + simulated digitizer + session writing + live data, as the Linux app runs
// it. Prints wall time, peak memory, live events received and the worst
// event loop lag of the main isolate (= UI thread stalls).
//
//   dart run tool/stress.dart [scenario ...]     (no argument = all)
import 'dart:async';
import 'dart:io';

import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

class Scenario {
  final String name;
  final double fs;
  final int n;
  final int records; // 0 = continuous for [duration]
  final double realtime;
  final Duration duration;
  final bool save;
  const Scenario(
    this.name,
    this.fs,
    this.n, {
    this.records = 1,
    this.realtime = 0,
    this.duration = const Duration(seconds: 5),
    this.save = true,
  });
}

const scenarios = [
  // the settings that froze the app: 1 MSa/s, 1000 samples, continuous
  Scenario('flood', 1e6, 1000, records: 0, realtime: 1, save: false),
  Scenario('mains', 1e4, 10000, records: 5),
  Scenario('hf-2M', 2e6, 2000000, records: 2),
  Scenario('hf-10M', 1e7, 10000000, records: 1),
  Scenario('huge-50M', 2e7, 50000000, records: 1),
  Scenario('rt-2M', 2e6, 2000000, records: 2, realtime: 1),
];

int _rssKb(String field) {
  final m = RegExp('$field:\\s+(\\d+)').firstMatch(File('/proc/self/status').readAsStringSync());
  return m == null ? 0 : int.parse(m[1]!);
}

Future<void> run(Scenario sc, String home) async {
  final tmp = Directory.systemTemp.createTempSync('twm_stress');
  final b = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/s.json');
  final s = await b.loadSettings();
  s.digitizer.type = DigitizerType.simulated;
  s.digitizer.onClose = OnCloseAction.immediateReset;
  s.digitizer.simulated
    ..realtimeFactor = sc.realtime
    ..maxFs = 1e9;
  s.measurement
    ..folder = tmp.path
    ..nameBase = 'stress'
    ..fs = sc.fs
    ..samplesCount = sc.n
    ..recordsCount = sc.records == 0 ? 1 : sc.records
    ..continuous = sc.records == 0
    ..saveRecords = sc.save
    ..processingEnabled = false;

  // main isolate lag probe: a 10 ms timer, worst delay = UI stall
  var worstLag = Duration.zero;
  final probe = Stopwatch()..start();
  var last = probe.elapsed;
  final lagTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final now = probe.elapsed;
    final lag = now - last - const Duration(milliseconds: 10);
    if (lag > worstLag) worstLag = lag;
    last = now;
  });

  var waveforms = 0, statuses = 0, lastRecord = 0;
  var decode = Duration.zero;
  final sw = Stopwatch()..start();
  final fin = Completer<FinishedEvent>();
  final sub = b.events.listen((e) {
    if (e is WaveformEvent) {
      waveforms++;
      lastRecord = e.record;
      final t = Stopwatch()..start();
      // what the UI does with it
      e.online == null ? null : OnlineResult.fromJson(e.online!);
      decode += t.elapsed;
    } else if (e is StatusEvent) {
      statuses++;
    } else if (e is FinishedEvent && !fin.isCompleted) {
      fin.complete(e);
    }
  });
  await b.startMeasurement(s);
  if (sc.records == 0) {
    await Future<void>.delayed(sc.duration);
    await b.stopMeasurement();
  }
  FinishedEvent? f;
  try {
    f = await fin.future.timeout(const Duration(minutes: 5));
  } on TimeoutException {
    stdout.writeln('${sc.name}: TIMEOUT');
  }
  sw.stop();
  lagTimer.cancel();
  await sub.cancel();
  final peakMb = _rssKb('VmHWM') / 1024;
  await b.dispose();
  tmp.deleteSync(recursive: true);
  final mss = sc.fs * sc.n / sc.fs; // samples per record
  stdout.writeln(
    '${sc.name.padRight(9)} fs=${(sc.fs / 1e6).toStringAsFixed(2)}M n=${(mss / 1e6).toStringAsFixed(3)}M '
    'time=${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s rec=$lastRecord '
    'waveforms=$waveforms status=$statuses uiLag=${worstLag.inMilliseconds}ms '
    'decode=${decode.inMilliseconds}ms peakRSS=${peakMb.toStringAsFixed(0)}MB '
    '${f == null ? '' : (f.error.isEmpty ? 'ok' : 'ERROR ${f.error}')}',
  );
}

Future<void> main(List<String> args) async {
  final home = Directory.current.parent.parent.path;
  for (final sc in scenarios) {
    if (args.isNotEmpty && !args.contains(sc.name)) continue;
    await run(sc, home);
  }
  exit(0);
}
