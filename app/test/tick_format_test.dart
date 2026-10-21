import 'package:flutter_test/flutter_test.dart';
import 'package:twm_app/widgets/chart.dart';

void main() {
  test('tick labels follow the step: no duplicates when zoomed, k/M for large values', () {
    final t = niceTicks(0.4775, 0.4812, 8);
    final labels = [for (final v in t) formatTick(v, t[1] - t[0])];
    expect(labels.toSet().length, labels.length, reason: '$labels');
    expect(formatTick(0.4775, 0.0005), '0.4775');
    expect(formatTick(120000, 20000), '120k');
    expect(formatTick(1500000, 500000), '1.5M');
    expect(formatTick(2, 1), '2');
    expect(formatTick(-6, 2), '-6');
    expect(formatTick(0.05, 0.05), '0.05');
  });
}
