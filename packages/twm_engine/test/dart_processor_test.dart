import 'dart:convert';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// Average of the results of several records (TWM result 0).
void main() {
  test('phases are wrapped to the display range before averaging (as qwtb_average_results.m)', () async {
    final store = MemoryFileStore();
    Map<String, Object?> rec(int r, double phi, double a) => {
      'group': 1,
      'record': r,
      'channels': [
        {
          'tag': 'u1',
          'quantities': [
            {
              'name': 'A',
              'v': [a],
            },
            {
              'name': 'phi',
              'v': [phi],
            },
          ],
        },
      ],
    };
    await store.writeText(
      '/m/RESULTS_WEB/TWM-PSFE.json',
      jsonEncode({
        'records': {'1-1': rec(1, 3.1, 1.0), '1-2': rec(2, -3.1, 2.0)},
      }),
    );
    await store.writeText(
      '/m/results_web.json',
      jsonEncode({
        'algorithms': ['TWM-PSFE'],
        'last': 'TWM-PSFE',
      }),
    );
    final dp = DartProcessor(store);
    Future<Map<String, double>> avg(PhaseMode m) async {
      final d = await dp.resultData('/m/session.info', 'TWM-PSFE', ResultViewConfig(resultId: 0, phase: m));
      return {for (final q in d.channels.first) q.name: q.value.first};
    }

    // +-pi: 3.1 and -3.1 average to 0; 0..2pi: 3.1 and 2pi-3.1 average to pi
    expect((await avg(PhaseMode.pmPi))['phi'], closeTo(0, 1e-12));
    expect((await avg(PhaseMode.zeroTwoPi))['phi'], closeTo(math.pi, 1e-12));
    expect((await avg(PhaseMode.zero360))['phi'], closeTo(180, 1e-9));
    expect((await avg(PhaseMode.pmPi))['A'], closeTo(1.5, 1e-12));
  });
}
