import 'package:twm_model/twm_model.dart';

import '../l10n.dart';

/// Checks of the QWTB processing setup against the measurement setup before
/// the start: warnings for the user (empty: nothing to report).
Future<List<String>> processingProblems(
  AppSettings settings, {
  required Future<AlgorithmInfo> Function(String id) algorithmInfo,
  required Future<OctaveStatus> Function() octaveStatus,
}) async {
  final m = settings.measurement;
  // continuous acquisition without saving: nothing is processed
  if (!m.processingEnabled || m.processing.mode != ProcessingMode.qwtb || (m.continuous && !m.saveRecords)) {
    return const [];
  }
  final out = <String>[];
  final alg = m.processing.algorithmId;
  // lowest input grid frequency of interest: 40 Hz
  final periods = m.samplesCount / m.fs * 40;
  if (periods < 5) {
    out.add(tr('The record holds less than 5 mains periods: the QWTB algorithms may fail or give wrong results.'));
  } else if (alg == 'TWM-THDWFFT' && periods < 30) {
    out.add(tr('TWM-THDWFFT needs at least 30 periods of the fundamental in the record (e.g. 0.75 s at 40 Hz).'));
  }
  try {
    final info = await algorithmInfo(alg);
    final t = settings.corrections.transducers;
    bool pair(int ph) =>
        t.any((x) => x.phaseIndex == ph && x.type == TransducerType.divider) &&
        t.any((x) => x.phaseIndex == ph && x.type == TransducerType.shunt);
    if (info.hasUi && !t.any((x) => pair(x.phaseIndex))) {
      out.add(
        trf(
          '{0} computes power: it needs a voltage and a current transducer (divider and shunt) with the same phase index in HW corrections.',
          [alg],
        ),
      );
    }
    // (Octave runs now: its status has the packages)
    final os = await octaveStatus();
    if (os.isOctave && os.failedPackages.isNotEmpty) {
      out.add(
        trf('GNU Octave packages not loaded: {0}. Some algorithms need them; on Ubuntu: sudo apt install {1}', [
          os.failedPackages.join(', '),
          os.failedPackages.map((p) => 'octave-$p').join(' '),
        ]),
      );
    }
  } catch (_) {
    // no calculation engine: the processing reports it itself
  }
  return out;
}
