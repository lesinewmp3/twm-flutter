// Long run of the desktop backend (isolate, engine, simulator, Octave) with
// random settings, abrupt stops and processing, to find crashes, hangs,
// memory growth and leftover Octave processes.
//
//   dart compile exe tool/soak.dart -o soak && ./soak <hours> <log file>
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

const home = '/home/e/papka_dlya_claude/twm_flutter';

late IOSink log;
void say(String s) {
  final line = '${DateTime.now().toIso8601String().substring(0, 19)} $s';
  log.writeln(line);
  stdout.writeln(line);
}

int rssMb() {
  final m = RegExp(r'VmRSS:\s+(\d+)').firstMatch(File('/proc/self/status').readAsStringSync());
  return m == null ? 0 : int.parse(m[1]!) ~/ 1024;
}

int octaveProcesses() {
  final r = Process.runSync('pgrep', ['-x', 'octave-cli']);
  return r.stdout.toString().trim().isEmpty ? 0 : r.stdout.toString().trim().split('\n').length;
}

/// Processing errors of setups the app warns about before the start: records
/// shorter than 5 periods at 40 Hz (TWM-PWRTDI and TWM-WRMS run out of DFT
/// bins), shorter than 30 periods for TWM-THDWFFT, power without a divider and
/// shunt pair.
bool expectedRefusal(String e, AppSettings s) {
  final m = s.measurement;
  final t = m.samplesCount / m.fs;
  final alg = m.processing.algorithmId;
  if (e.contains('Distance between the harmonics')) return alg == 'TWM-THDWFFT' && t < 30 / 40;
  if (e.contains('nonconformant')) return (alg == 'TWM-PWRTDI' || alg == 'TWM-WRMS') && t < 5 / 40;
  if (e.contains("Missing 'i' channel")) return alg == 'TWM-PWRTDI' && s.corrections.transducers.isEmpty;
  return false;
}

Future<void> main(List<String> args) async {
  final hours = args.isEmpty ? 1.0 : double.parse(args[0]);
  log = File(args.length > 1 ? args[1] : 'soak.log').openWrite(mode: FileMode.append);
  final rnd = math.Random(DateTime.now().millisecondsSinceEpoch);
  final end = DateTime.now().add(Duration(minutes: (hours * 60).round()));
  final tmp = Directory.systemTemp.createTempSync('twm_soak');
  final b = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/s.json');
  final events = <BackendEvent>[];
  b.events.listen(events.add);
  var n = 0, failures = 0, expectedErrors = 0;
  final rss0 = rssMb();
  final algs = ['TWM-PSFE', 'TWM-WRMS', 'TWM-PWRTDI', 'TWM-WFFT', 'TWM-THDWFFT'];
  say('soak start: $hours h, rss $rss0 MB');

  while (DateTime.now().isBefore(end)) {
    n++;
    events.clear();
    final s = await b.loadSettings();
    s.digitizer
      ..type = DigitizerType.simulated
      ..onClose = rnd.nextBool() ? OnCloseAction.immediateReset : OnCloseAction.delayedReset;
    final sim = s.digitizer.simulated
      ..maxFs = 1e8
      ..realtimeFactor = rnd.nextInt(4) == 0 ? 1 : 0
      ..jitterRms = rnd.nextInt(5) == 0 ? 1e-7 : 0
      ..bits = [16, 20, 24][rnd.nextInt(3)];
    for (final c in sim.channels) {
      c.harmonics = [
        SimHarmonic(40 + rnd.nextDouble() * 25, (c.range * 0.2) + rnd.nextDouble() * c.range * 0.6, rnd.nextDouble() * 6 - 3),
        for (var k = 0; k < rnd.nextInt(4); k++) SimHarmonic(rnd.nextDouble() * 5000, c.range * 0.01 * rnd.nextDouble()),
      ];
      c.noiseRms = rnd.nextBool() ? 1e-6 : 1e-4;
    }
    // occasionally an overload (must stop with an error, not crash)
    final overload = rnd.nextInt(12) == 0;
    if (overload) sim.channels.last.harmonics.first.amp = sim.channels.last.range * 1.5;
    final kind = rnd.nextInt(5);
    final fs = switch (kind) {
      0 => 1e6, // short records, continuous
      1 => [1e4, 2e4, 5e4][rnd.nextInt(3)],
      2 => 2e6,
      _ => 1000 + rnd.nextDouble() * 199000,
    };
    final samples = switch (kind) {
      0 => 1000 + rnd.nextInt(2000),
      2 => 200000 + rnd.nextInt(1800000),
      _ => 1000 + rnd.nextInt(60000),
    };
    s.measurement
      ..folder = '${tmp.path}/m'
      ..nameBase = 'soak'
      ..fs = fs
      ..samplesCount = samples
      ..recordsCount = 1 + rnd.nextInt(4)
      ..continuous = kind == 0
      ..saveRecords = kind != 0 || rnd.nextBool()
      ..processingEnabled = kind != 0 && rnd.nextInt(3) == 0
      ..processing.algorithmId = algs[rnd.nextInt(algs.length)];
    s.online
      ..harmonics = 1 + rnd.nextInt(50)
      ..window = WindowType.values[rnd.nextInt(WindowType.values.length)]
      ..statistics = rnd.nextBool()
      ..monitorWindowMs = [0.0, 20.0, 80.0, 1000.0][rnd.nextInt(4)];
    if (rnd.nextBool()) {
      s.corrections.transducers = [
        TransducerConfig(path: r'dummy.vd\dummy.info', highChannel: 1, nominalRatio: 1),
        TransducerConfig(path: r'dummy.cs\dummy.info', type: TransducerType.shunt, highChannel: 2, nominalRatio: 1),
      ];
    }
    // stop randomly during the run (or let it finish)
    final stopAfter = kind == 0 || rnd.nextInt(4) == 0 ? Duration(milliseconds: 200 + rnd.nextInt(4000)) : null;
    final desc =
        'kind=$kind fs=${fs.round()} N=$samples rec=${s.measurement.recordsCount} rt=${sim.realtimeFactor} '
        'bits=${sim.bits} proc=${s.measurement.processingEnabled ? s.measurement.processing.algorithmId : '-'} '
        'mon=${s.online.monitorWindowMs} ovl=$overload stop=${stopAfter?.inMilliseconds}';
    final sw = Stopwatch()..start();
    String result;
    try {
      final coll = await b.collidingFiles(s.measurement);
      if (coll.isNotEmpty) await b.clearSession(s.measurement);
      await b.startMeasurement(s);
      if (stopAfter != null) {
        await Future<void>.delayed(stopAfter);
        await b.stopMeasurement();
      }
      // finished, then the processing of the records (if any) completes
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (!events.any((e) => e is FinishedEvent)) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('measurement did not finish');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (s.measurement.processingEnabled) {
        while (events.whereType<ProcessingEvent>().isNotEmpty && events.whereType<ProcessingEvent>().last.busy) {
          if (DateTime.now().isAfter(deadline)) throw TimeoutException('processing did not finish');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      final fin = events.whereType<FinishedEvent>().first;
      final procErr = events.whereType<ProcessingEvent>().where((e) => e.error.isNotEmpty).map((e) => e.error);
      if (fin.error.isNotEmpty) {
        if (overload && fin.error.contains('Overload')) {
          expectedErrors++;
          result = 'ok (overload detected)';
        } else {
          failures++;
          result = 'FAIL finished with error: ${fin.error}';
        }
      } else if (overload && !fin.aborted) {
        failures++;
        result = 'FAIL overload not detected';
      } else if (procErr.isNotEmpty && procErr.every((e) => expectedRefusal(e, s))) {
        // the algorithm refuses a setup the app warns about before the start
        expectedErrors++;
        result = 'ok (algorithm precondition: ${procErr.first.split('\n').first})';
      } else if (procErr.isNotEmpty) {
        failures++;
        result = 'FAIL processing: ${procErr.first}';
      } else {
        final live = events.whereType<LiveEvent>().length, wf = events.whereType<WaveformEvent>().length;
        result = 'ok live=$live wf=$wf${fin.aborted ? ' (stopped)' : ''}';
      }
    } catch (e) {
      failures++;
      result = 'FAIL exception: $e';
      // a hang: make sure the next run is not blocked
      try {
        await b.stopMeasurement();
        await b.stopProcessing();
      } catch (_) {}
    }
    say('#$n ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s rss=${rssMb()}MB octave=${octaveProcesses()} $desc -> $result');
    // keep the disk clean
    try {
      Directory('${tmp.path}/m').deleteSync(recursive: true);
    } catch (_) {}
  }
  say('soak end: runs=$n failures=$failures expected_errors=$expectedErrors rss ${rss0}MB -> ${rssMb()}MB');
  await b.dispose();
  say('after dispose: octave processes ${octaveProcesses()}');
  await log.close();
  tmp.deleteSync(recursive: true);
  exit(failures == 0 ? 0 : 1);
}
