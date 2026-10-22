import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

/// Spectra for the display and the on-line analysis (TPQA) of one record.
class RecordAnalysis {
  /// Channel spectra decimated for the display and their bin width [Hz].
  final List<Float64List> spectra;
  final double df;
  final OnlineResult? online;
  final String error;
  const RecordAnalysis({this.spectra = const [], this.df = 0, this.online, this.error = ''});
}

/// Analysis of the records of one measurement, in their order (the on-line
/// statistics run over the records).
abstract class RecordAnalyzer {
  Future<RecordAnalysis> analyze(List<Float64List> channels, double fs);
  Future<void> close();
}

/// Analysis in the calling isolate (browser, tests); the desktop runs the
/// same in a worker isolate so the acquisition does not wait for it.
class InlineRecordAnalyzer implements RecordAnalyzer {
  final AppSettings settings;
  final OnlineAnalyzer _online;
  InlineRecordAnalyzer(this.settings) : _online = OnlineAnalyzer(settings.online);

  RecordAnalysis run(List<Float64List> channels, double fs) {
    final s = settings;
    final spectra = channels.isEmpty || channels.first.length < 2
        ? const <Spectrum>[]
        : [for (final c in channels) Spectrum.of(c, fs, window: s.online.window)];
    OnlineResult? res;
    var error = '';
    if (s.online.enabled) {
      try {
        res = _online.analyze(channels, fs, s.corrections.transducers, spectra: spectra);
      } catch (e) {
        error = '$e';
      }
    }
    final display = <Float64List>[];
    var df = 0.0;
    for (final sp in spectra) {
      df = sp.df;
      display.add(Float64List.fromList(sp.forDisplay(4096)));
    }
    if (spectra.isNotEmpty) {
      // display decimation of the spectrum changes the bin width
      final n = spectra.first.amp.length;
      if (display.first.length < n) df *= (n / display.first.length).ceilToDouble();
    }
    return RecordAnalysis(spectra: display, df: df, online: res, error: error);
  }

  @override
  Future<RecordAnalysis> analyze(List<Float64List> channels, double fs) async => run(channels, fs);

  @override
  Future<void> close() async {}
}
