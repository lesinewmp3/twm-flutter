import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/l10n.dart';
import 'package:twm_app/state/start_checks.dart';
import 'package:twm_model/twm_model.dart';

/// Checks of the processing setup before the start (warnings to the user).
void main() {
  setUp(() => L10n.apply('en'));

  AppSettings settings({String alg = 'TWM-PSFE', double fs = 10000, int n = 10000, bool pair = false}) => AppSettings()
    ..measurement.processingEnabled = true
    ..measurement.processing.algorithmId = alg
    ..measurement.fs = fs
    ..measurement.samplesCount = n
    ..corrections.transducers = [
      if (pair) ...[
        TransducerConfig(path: 'u.info', highChannel: 1),
        TransducerConfig(path: 'i.info', type: TransducerType.shunt, highChannel: 2),
      ],
    ];

  Future<List<String>> check(
    AppSettings s, {
    bool hasUi = false,
    List<String> failed = const [],
    bool noEngine = false,
  }) => processingProblems(
    s,
    algorithmInfo: (id) async =>
        noEngine ? throw StateError('no Octave') : AlgorithmInfo(id: id, name: id, hasUi: hasUi),
    octaveStatus: () async => OctaveStatus(running: true, failedPackages: failed),
  );

  test('nothing to report', () async {
    expect(await check(settings()), isEmpty);
    expect(await check(settings(alg: 'TWM-PWRTDI', pair: true), hasUi: true), isEmpty);
    // processing off: no checks
    expect(await check(settings(n: 10)..measurement.processingEnabled = false), isEmpty);
    // continuous with parallel record processing: no dead time
    expect(
      await check(
        settings()
          ..measurement.continuous = true
          ..measurement.processing.execution = ExecutionMode.parallelRecords,
      ),
      isEmpty,
    );
  });

  test('continuous measurement', () async {
    // without saving: nothing would be processed (only this warning)
    final unsaved = await check(
      settings(n: 10)
        ..measurement.continuous = true
        ..measurement.saveRecords = false,
    );
    expect(unsaved, hasLength(1));
    expect(unsaved.first, contains('without saving'));
    // single-core processing stops the acquisition after every record
    final w = await check(settings()..measurement.continuous = true);
    expect(w, hasLength(1));
    expect(w.first, contains('Parallel record processing'));
  });

  test('short records', () async {
    expect((await check(settings(n: 1000))).single, contains('less than 5 mains periods'));
    expect((await check(settings(alg: 'TWM-THDWFFT', n: 5000))).single, contains('at least 30 periods'));
    expect(await check(settings(alg: 'TWM-THDWFFT', n: 8000)), isEmpty);
    // TWM-WRMS / TWM-PWRTDI: 2000 samples (10 kSa/s, 0.2 s) fail, 3000 do not
    expect((await check(settings(alg: 'TWM-WRMS', n: 2000))).single, contains('shorter than 3000 samples'));
    expect(await check(settings(alg: 'TWM-WRMS', n: 3000)), isEmpty);
    expect(
      (await check(settings(alg: 'TWM-PWRTDI', n: 2000, pair: true), hasUi: true)).single,
      contains('TWM-PWRTDI may fail'),
    );
  });

  test('power algorithm needs a divider and a shunt of one phase', () async {
    expect((await check(settings(alg: 'TWM-PWRTDI'), hasUi: true)).single, contains('needs a voltage and a current'));
  });

  test('Octave packages that did not load: the apt command', () async {
    final w = (await check(settings(), failed: ['signal', 'statistics'])).single;
    expect(w, contains('GNU Octave packages not loaded: signal, statistics'));
    expect(w, contains('sudo apt install octave-signal octave-statistics'));
    L10n.apply('ru');
    expect(
      (await check(settings(), failed: ['signal'])).single,
      'Не загружены пакеты GNU Octave: signal. Они нужны части алгоритмов; в Ubuntu: sudo apt install octave-signal',
    );
  });

  test('no calculation engine: only the record checks', () async {
    expect((await check(settings(n: 1000), noEngine: true)).single, contains('less than 5 mains periods'));
  });
}
