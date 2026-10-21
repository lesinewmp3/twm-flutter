import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// A fast continuous acquisition must not flood the UI with live data.
void main() {
  test('live waveforms are throttled, the last record is delivered', () async {
    final out = <BackendEvent>[];
    final m = MeasEventMapper(MemoryFileStore(), AppSettings(), out.add);
    final x = Float64List.fromList([for (var i = 0; i < 1000; i++) math.sin(2 * math.pi * 50 * i / 1e4)]);
    for (var r = 1; r <= 200; r++) {
      await m.handle(MeasStatus('Digitizing record $r...', record: r));
      await m.handle(MeasRecordData(r, [x], 1e-4, ['u'], [x], 1e-4));
    }
    await m.handle(const MeasFinished(''));
    final wf = out.whereType<WaveformEvent>().toList();
    expect(wf.length, lessThan(10));
    expect(wf.last.record, 200);
    expect(wf.last.online, isNotNull);
    expect(out.whereType<StatusEvent>().length, lessThan(10));
    expect(out.last, isA<FinishedEvent>());
  });
}
