// Long run of continuous measurements ("Continuous until STOP") of the
// desktop backend (isolate, engine, simulator in real time, GNU Octave) with
// random realistic setups. Every run checks the invariants a user sees:
// the measurement stops quickly and cleanly, the records follow each other
// without dead time (unless single-core processing is chosen), the monitor
// shows whole triggered windows without long gaps, every stored record is
// processed once without errors, events (sag / interruption / transfer) are
// measured, the session header stays readable while it is rewritten.
//
//   dart run tool/soak_continuous.dart <hours> <log file>
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:twm_core/twm_core.dart';
import 'package:twm_model/twm_model.dart';

final home = AppPaths.resolve().home;

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

Future<void> main(List<String> args) async {
  final hours = args.isEmpty ? 1.0 : double.parse(args[0]);
  log = File(args.length > 1 ? args[1] : 'soak_continuous.log').openWrite(mode: FileMode.append);
  final seed = DateTime.now().millisecondsSinceEpoch;
  final rnd = math.Random(seed);
  final end = DateTime.now().add(Duration(minutes: (hours * 60).round()));
  final tmp = Directory.systemTemp.createTempSync('twm_csoak');
  final b = await IsolateBackend.spawn(home: home, settingsFile: '${tmp.path}/s.json');
  final events = <(int, BackendEvent)>[];
  final sw = Stopwatch()..start();
  b.events.listen((e) => events.add((sw.elapsedMilliseconds, e)));
  var n = 0, failed = 0;
  final failures = <String, int>{};
  final rss0 = rssMb();
  final dead = <String, List<double>>{};
  say('continuous soak start: $hours h, seed $seed, rss $rss0 MB');

  while (DateTime.now().isBefore(end)) {
    n++;
    events.clear();
    final problems = <String>[];
    void bad(String what) => problems.add(what);

    final s = await b.loadSettings();
    s.digitizer
      ..type = DigitizerType.simulated
      ..onClose = OnCloseAction.immediateReset;
    // mains 40..60 Hz with harmonics and noise; a sag / interruption / transfer
    // in every record sometimes
    final f0 = [50.0, 40 + rnd.nextDouble() * 20][rnd.nextInt(2)];
    final sim = s.digitizer.simulated
      ..maxFs = 1e8
      ..realtimeFactor = 1
      ..jitterRms = 0
      ..bits = [16, 24][rnd.nextInt(2)];
    final fs = [10000.0, 50000.0, 100000.0, 200000.0, 500000.0, 1e6, 2e6][rnd.nextInt(7)];
    final tRec = [0.05, 0.1, 0.2, 0.5, 1.0, 2.0][rnd.nextInt(6)];
    final samples = math.min((fs * tRec).round(), 4000000);
    final t = samples / fs;
    final withEvent = rnd.nextInt(3) == 0 && t >= 0.1;
    final ev = withEvent
        ? SimEvent(
            start: 0.02 + rnd.nextDouble() * (t - 0.06),
            duration: 0.001 + rnd.nextDouble() * 0.008,
            level: [0.0, 0.4, 0.7][rnd.nextInt(3)],
            phaseJump: rnd.nextBool() ? 0 : 0.5,
          )
        : null;
    for (final c in sim.channels) {
      c.harmonics = [
        SimHarmonic(f0, c.range * (0.3 + rnd.nextDouble() * 0.5), rnd.nextDouble() * 6 - 3),
        SimHarmonic(3 * f0, c.range * 0.01, 0.3),
        if (fs >= 200000) SimHarmonic(20000 + rnd.nextDouble() * 120000, c.range * 0.005),
      ];
      c.noiseRms = [1e-6, 1e-4, 1e-3][rnd.nextInt(3)];
      c.event = ev;
    }
    final save = rnd.nextInt(5) != 0;
    // processing only where GNU Octave keeps up with a few records (<= 0.4 MSa)
    final process = save && samples <= 400000 && t * f0 >= 5 && rnd.nextInt(3) != 0;
    final algs = ['TWM-PSFE', 'TWM-WRMS', 'TWM-WFFT', if (t * 40 >= 30) 'TWM-THDWFFT', 'TWM-PWRTDI'];
    final alg = algs[rnd.nextInt(algs.length)];
    final parallel = rnd.nextBool();
    final atOnce = process && (alg == 'TWM-WFFT' || alg == 'TWM-THDWFFT') && rnd.nextInt(3) == 0;
    s.measurement
      ..folder = '${tmp.path}/m'
      ..nameBase = 'cs'
      ..fs = fs
      ..samplesCount = samples
      ..continuous = true
      ..saveRecords = save
      ..processingEnabled = process
      ..processing.algorithmId = alg
      ..processing.execution = parallel ? ExecutionMode.parallelRecords : ExecutionMode.singleCore
      ..processing.wholeAverageAtOnce = atOnce;
    s.corrections.transducers = alg == 'TWM-PWRTDI'
        ? [
            TransducerConfig(path: r'dummy.vd\dummy.info', highChannel: 1, nominalRatio: 1),
            TransducerConfig(path: r'dummy.cs\dummy.info', type: TransducerType.shunt, highChannel: 2, nominalRatio: 1),
          ]
        : [];
    final monMs = [20.0, 80.0, 200.0, 1000.0][rnd.nextInt(4)];
    s.online
      ..monitorWindowMs = monMs
      ..transferAnalysis = withEvent || rnd.nextBool()
      ..harmonics = 1 + rnd.nextInt(40);
    final runFor = Duration(milliseconds: 3000 + rnd.nextInt(30000));
    final desc =
        'fs=${fs.round()} T=${t}s f0=${f0.toStringAsFixed(2)} save=$save '
        'proc=${process ? '$alg${parallel ? '/par' : '/seq'}${atOnce ? '/once' : ''}' : '-'} '
        'mon=${monMs.round()}ms ev=${ev == null ? '-' : '${(ev.duration * 1000).toStringAsFixed(2)}ms@${ev.level}'} '
        'run=${(runFor.inMilliseconds / 1000).toStringAsFixed(1)}s';

    final t0 = sw.elapsedMilliseconds;
    var headerReads = 0, headerErrors = 0;
    try {
      final coll = await b.collidingFiles(s.measurement);
      if (coll.isNotEmpty) await b.clearSession(s.measurement);
      final session = await b.startMeasurement(s);
      // read the session header as the viewers do while it is rewritten
      final readEnd = DateTime.now().add(runFor);
      while (DateTime.now().isBefore(readEnd)) {
        await Future<void>.delayed(Duration(milliseconds: 150 + rnd.nextInt(200)));
        if (save && events.any((e) => e.$2 is RecordStoredEvent)) {
          headerReads++;
          try {
            await b.sessionSummary(session);
          } catch (e) {
            headerErrors++;
            if (headerErrors == 1) bad('session header unreadable during the measurement: $e');
          }
        }
      }
      final tStop = sw.elapsedMilliseconds;
      await b.stopMeasurement();
      final finDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (!events.any((e) => e.$2 is FinishedEvent)) {
        if (DateTime.now().isAfter(finDeadline)) throw TimeoutException('no finish 60 s after STOP');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final finAt = events.firstWhere((e) => e.$2 is FinishedEvent);
      final fin = finAt.$2 as FinishedEvent;
      final stopMs = finAt.$1 - tStop;
      if (fin.error.isNotEmpty) bad('finished with error: ${fin.error}');
      // STOP waits for the record being processed (single-core), else at most
      // the current fetch
      final stopLimit = process && !parallel ? 20000 : 1500;
      if (stopMs > stopLimit) bad('STOP took $stopMs ms');

      // records follow each other: dead time between the stored records
      final stored = [
        for (final e in events)
          if (e.$2 is RecordStoredEvent) e.$1,
      ];
      final waves = [
        for (final e in events)
          if (e.$2 is WaveformEvent) (e.$1, e.$2 as WaveformEvent),
      ];
      final recTimes = save ? stored : [for (final w in waves) w.$1];
      var deadPct = double.nan;
      if (recTimes.length >= 3) {
        final span = (recTimes.last - recTimes.first) / 1000;
        final recs = recTimes.length - 1;
        deadPct = 100 * (1 - recs * t / span);
        final key = process && !parallel ? 'seq' : 'free';
        (dead[key] ??= []).add(deadPct);
        // without single-core processing: record overhead below 50 ms + 10 %
        if (key == 'free' && span / recs > t * 1.1 + 0.05) {
          bad(
            'dead time ${deadPct.toStringAsFixed(1)} % (${(span / recs * 1000).round()} ms per ${t * 1000} ms record)',
          );
        }
      }

      // monitor: whole windows on the trigger, no long gaps
      final live = [
        for (final e in events)
          if (e.$2 is LiveEvent) (e.$1, e.$2 as LiveEvent),
      ];
      final w = math.min((monMs / 1000 * fs).round(), samples) / fs;
      if (live.isEmpty) {
        bad('no monitor frames');
      } else {
        final canTrigger = samples / fs >= w + 1.5 / f0 && w >= 1.2 / f0;
        var short = 0, untrig = 0;
        for (final (k, (_, f)) in live.indexed) {
          if ((f.span - w).abs() > 1.5 / fs) short++;
          if (k > 0 && canTrigger && !f.triggered) untrig++;
        }
        if (short > 0) bad('$short of ${live.length} monitor frames not ${w * 1000} ms long');
        // an interruption in the window may hide the trigger for a frame or two
        if (untrig > (ev != null && ev.level == 0 ? live.length ~/ 10 : 0)) {
          bad('$untrig of ${live.length} monitor frames not triggered');
        }
        var gap = 0;
        for (var k = 1; k < live.length; k++) {
          if (live[k].$2.record == live[k - 1].$2.record) continue;
          gap = math.max(gap, live[k].$1 - live[k - 1].$1);
        }
        var inGap = 0;
        for (var k = 1; k < live.length; k++) {
          if (live[k].$2.record != live[k - 1].$2.record) continue;
          inGap = math.max(inGap, live[k].$1 - live[k - 1].$1);
        }
        // inside a record: 25 ms frames; at a record start: a whole window
        // (+ a period for the trigger) of the new record
        if (inGap > 250) bad('monitor gap $inGap ms inside a record');
        final limit = (w + 1.5 / f0) * 1000 + 300 + (process && !parallel ? 30000 : 0);
        if (gap > limit) bad('monitor gap $gap ms at a record start (limit ${limit.round()})');
      }

      // events: every record with the whole event inside it
      if (ev != null && s.online.transferAnalysis && ev.start + ev.duration < t - 0.01) {
        var checked = 0, wrong = 0;
        String? first;
        for (final (_, wf) in waves) {
          final o = wf.online == null ? null : OnlineResult.fromJson(wf.online!);
          if (o == null) continue;
          double? q(String name) {
            for (final x in o.quantities) {
              if (x.name == name) return x.value;
            }
            return null;
          }

          final dur = q('Event duration u1'), at = q('Event start u1');
          checked++;
          // depth below the 90 % threshold: 0 / 40 / 70 % levels are events
          final okDur = dur != null && (dur - ev.duration * 1000).abs() < 0.25 + 2000 / fs;
          final okAt = at != null && (at - ev.start * 1000).abs() < 0.25 + 2000 / fs;
          if (!okDur || !okAt) {
            wrong++;
            first ??= 'duration $dur ms start $at ms (true ${ev.duration * 1000} ms at ${ev.start * 1000} ms)';
          }
        }
        if (checked == 0) bad('no on-line results for the event');
        if (wrong > 0) bad('event wrong in $wrong of $checked records: $first');
      }

      // processing: every stored record once (whole average: at STOP)
      final nStored = stored.length;
      if (process && nStored > 0) {
        final procEnd = DateTime.now().add(const Duration(minutes: 10));
        bool idle() {
          final p = events.where((e) => e.$2 is ProcessingEvent).map((e) => e.$2 as ProcessingEvent).toList();
          if (p.isEmpty || p.last.busy) return false;
          final ok = p.where((e) => !e.busy).map((e) => e.record).toSet();
          return ok.length >= nStored;
        }

        while (!idle() && DateTime.now().isBefore(procEnd)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final p = events.where((e) => e.$2 is ProcessingEvent).map((e) => e.$2 as ProcessingEvent).toList();
        final errs = p.where((e) => e.error.isNotEmpty).toList();
        if (errs.isNotEmpty)
          bad('processing errors (${errs.length}): record ${errs.first.record}: ${errs.first.error}');
        final done = [
          for (final e in p)
            if (!e.busy && e.error.isEmpty) e.record,
        ];
        final expected = [for (var r = 1; r <= nStored; r++) r, if (atOnce) nStored];
        if (done.join(',') != expected.join(',')) {
          bad('processed records [${done.join(',')}] instead of 1..$nStored${atOnce ? ' + final' : ''}');
        }
        if (errs.isEmpty) {
          final ri = await b.resultsInfo(fin.sessionPath);
          if (!ri.algorithms.contains(alg)) bad('no $alg results in the session');
        }
      }

      // the stored session
      if (save && nStored > 0) {
        final sum = await b.sessionSummary(fin.sessionPath);
        if (sum.recordsPerGroup.join(',') != '$nStored') {
          bad('session has ${sum.recordsPerGroup} records, $nStored stored');
        }
        final wd = await b.readRecord(fin.sessionPath, 1, nStored, maxPoints: 1000);
        if (wd.channels.isEmpty) bad('last record unreadable');
        final dir = Directory(fin.sessionPath).parent;
        final tmpFiles = dir.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')).length;
        if (tmpFiles > 0) bad('$tmpFiles temporary files left in the session');
      }

      final result = problems.isEmpty ? 'ok' : 'FAIL ${problems.join('; ')}';
      if (problems.isNotEmpty) {
        failed++;
        for (final p in problems) {
          final k = p.replaceAll(RegExp(r'[\d.]+'), '#');
          failures[k] = (failures[k] ?? 0) + 1;
        }
      }
      say(
        '#$n ${((sw.elapsedMilliseconds - t0) / 1000).toStringAsFixed(1)}s rss=${rssMb()}MB octave=${octaveProcesses()} '
        '$desc -> rec=$nStored wf=${waves.length} live=${live.length} dead=${deadPct.toStringAsFixed(1)}% '
        'stop=${stopMs}ms hdr=$headerReads $result',
      );
    } catch (e) {
      failed++;
      final k = 'exception: ${'$e'.replaceAll(RegExp(r'[\d.]+'), '#')}';
      failures[k] = (failures[k] ?? 0) + 1;
      say('#$n $desc -> FAIL exception: $e');
      try {
        await b.stopMeasurement();
        await b.stopProcessing();
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    try {
      Directory('${tmp.path}/m').deleteSync(recursive: true);
    } catch (_) {}
  }
  String stats(List<double>? v) {
    if (v == null || v.isEmpty) return '-';
    final x = [...v]..sort();
    return 'median ${x[x.length ~/ 2].toStringAsFixed(1)} % max ${x.last.toStringAsFixed(1)} % (${x.length} runs)';
  }

  say('dead time without single-core processing: ${stats(dead['free'])}; with single-core: ${stats(dead['seq'])}');
  for (final e in failures.entries) {
    say('failure x${e.value}: ${e.key}');
  }
  say('continuous soak end: runs=$n failed=$failed rss ${rss0}MB -> ${rssMb()}MB');
  await b.dispose();
  say('after dispose: octave processes ${octaveProcesses()}');
  await log.close();
  tmp.deleteSync(recursive: true);
  exit(failed == 0 ? 0 : 1);
}
