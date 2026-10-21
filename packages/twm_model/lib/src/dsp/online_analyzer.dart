/// On-line (quasi real-time) analysis of TPQA "CVI Data Processing" panel:
/// per channel RMS/DC/frequency/harmonics/THD, per phase power quantities,
/// optional running statistics over the last N acquisitions.
library;

import 'dart:typed_data';

import '../json.dart';
import '../models/measurement.dart';
import 'dsp.dart';

class OnlineAnalysisConfig {
  bool enabled;
  bool harmonicAnalyzer;
  int harmonics;
  WindowType window;
  bool statistics;
  int averageCycles;

  /// TPQA "Save CVI Processed Data": append results of every acquisition
  /// to a CSV file ([resultsFile]).
  bool saveResults;
  String resultsFile;

  OnlineAnalysisConfig({
    this.enabled = true,
    this.harmonicAnalyzer = true,
    this.harmonics = 20,
    this.window = WindowType.hann,
    this.statistics = false,
    this.averageCycles = 10,
    this.saveResults = false,
    this.resultsFile = '',
  });

  Json toJson() => {
    'enabled': enabled,
    'harmonicAnalyzer': harmonicAnalyzer,
    'harmonics': harmonics,
    'window': window.name,
    'statistics': statistics,
    'averageCycles': averageCycles,
    'saveResults': saveResults,
    'resultsFile': resultsFile,
  };

  factory OnlineAnalysisConfig.fromJson(Json j) => OnlineAnalysisConfig(
    enabled: jBool(j['enabled'], true),
    harmonicAnalyzer: jBool(j['harmonicAnalyzer'], true),
    harmonics: jInt(j['harmonics'], 20),
    window: enumByName(WindowType.values, j['window'], WindowType.hann),
    statistics: jBool(j['statistics']),
    averageCycles: jInt(j['averageCycles'], 10),
    saveResults: jBool(j['saveResults']),
    resultsFile: jString(j['resultsFile']),
  );
}

/// One line of the on-line results grid.
class OnlineQuantity {
  final String name; // e.g. "RMS u1"
  final String unit;
  final double value;
  final double mean;
  final double std;
  final double uA;
  final double errorPercent;
  final int count;
  const OnlineQuantity(
    this.name,
    this.unit,
    this.value, {
    this.mean = double.nan,
    this.std = double.nan,
    this.uA = double.nan,
    this.errorPercent = double.nan,
    this.count = 0,
  });

  Json toJson() => {
    'name': name,
    'unit': unit,
    'value': jNum(value),
    'mean': jNum(mean),
    'std': jNum(std),
    'uA': jNum(uA),
    'err': jNum(errorPercent),
    'count': count,
  };
  factory OnlineQuantity.fromJson(Json j) => OnlineQuantity(
    jString(j['name']),
    jString(j['unit']),
    jDouble(j['value'], double.nan),
    mean: jDouble(j['mean'], double.nan),
    std: jDouble(j['std'], double.nan),
    uA: jDouble(j['uA'], double.nan),
    errorPercent: jDouble(j['err'], double.nan),
    count: jInt(j['count']),
  );
}

class OnlineResult {
  final List<OnlineQuantity> quantities;

  /// Harmonic amplitudes per channel tag (for the harmonic graphs).
  final Map<String, List<double>> harmonics;
  final double f0;
  const OnlineResult(this.quantities, this.harmonics, this.f0);

  Json toJson() => {
    'quantities': [for (final q in quantities) q.toJson()],
    'harmonics': {for (final e in harmonics.entries) e.key: [for (final v in e.value) jNum(v)]},
    'f0': jNum(f0),
  };
  factory OnlineResult.fromJson(Json j) => OnlineResult(
    [for (final q in jMapList(j['quantities'])) OnlineQuantity.fromJson(q)],
    {for (final e in jMap(j['harmonics']).entries) e.key: jDoubleList(e.value)},
    jDouble(j['f0'], double.nan),
  );
}

class OnlineAnalyzer {
  OnlineAnalysisConfig config;
  final Map<String, RunningStat> _stats = {};
  OnlineAnalyzer(this.config);

  void reset() => _stats.clear();

  /// [channels] are the scaled digitizer channels; [transducers] define
  /// voltage/current channels and their ratio (output -> input quantity)
  /// and pairing into phases. Without transducers each channel is a voltage.
  OnlineResult analyze(List<Float64List> channels, double fs, List<TransducerConfig> transducers) {
    final q = <OnlineQuantity>[];
    final harm = <String, List<double>>{};
    final sig = <String, Float64List>{};
    final tags = <String>[];
    if (transducers.isEmpty) {
      for (var c = 0; c < channels.length; c++) {
        final tag = 'u${c + 1}';
        sig[tag] = channels[c];
        tags.add(tag);
      }
    } else {
      for (final t in transducers) {
        final hi = t.highChannel - 1;
        if (hi < 0 || hi >= channels.length) continue;
        final lo = t.lowChannel - 1;
        final x = Float64List(channels[hi].length);
        final ratio = t.nominalRatio.isFinite && t.nominalRatio != 0 ? t.nominalRatio : 1.0;
        // shunt ratio is V/A (divide), divider ratio is Vin/Vout (multiply)
        final k = (t.type == TransducerType.shunt ? 1 / ratio : ratio) * (t.inverted ? -1 : 1);
        for (var i = 0; i < x.length; i++) {
          final v = channels[hi][i] - (lo >= 0 && lo < channels.length ? channels[lo][i] : 0);
          x[i] = v * k;
        }
        final tag = '${t.type == TransducerType.shunt ? 'i' : 'u'}${t.phaseIndex}';
        sig[tag] = x;
        tags.add(tag);
      }
    }
    var f0 = double.nan;
    for (final tag in tags) {
      final x = sig[tag]!;
      final unit = tag.startsWith('i') ? 'A' : 'V';
      final h = HarmonicAnalysis.of(
        x,
        fs,
        harmonics: config.harmonicAnalyzer ? config.harmonics : 1,
        window: config.window,
      );
      if (f0.isNaN) f0 = h.f0;
      q.add(_q('RMS $tag', unit, h.rms));
      q.add(_q('DC $tag', unit, h.dc));
      q.add(_q('f $tag', 'Hz', h.f0));
      q.add(_q('A1 $tag', unit, h.amplitudes.first));
      q.add(_q('phi1 $tag', 'rad', h.phases.first));
      if (config.harmonicAnalyzer) {
        q.add(_q('THD $tag', '%', h.thd * 100));
        harm[tag] = h.amplitudes;
      }
    }
    // phases: pair u<k> with i<k>
    final phases = {for (final t in tags) t.substring(1)};
    for (final ph in phases) {
      final u = sig['u$ph'], i = sig['i$ph'];
      if (u == null || i == null) continue;
      final p = PowerAnalysis.of(u, i);
      q.add(_q('P L$ph', 'W', p.p));
      q.add(_q('Q L$ph', 'var', p.q));
      q.add(_q('S L$ph', 'VA', p.s));
      q.add(_q('PF L$ph', '-', p.pf));
    }
    return OnlineResult(q, harm, f0);
  }

  OnlineQuantity _q(String name, String unit, double v) {
    if (!config.statistics) return OnlineQuantity(name, unit, v);
    final s = _stats.putIfAbsent(name, () => RunningStat(config.averageCycles));
    s.add(v);
    return OnlineQuantity(
      name,
      unit,
      v,
      mean: s.average,
      std: s.std,
      uA: s.uA,
      errorPercent: s.errorPercent,
      count: s.values.length,
    );
  }
}

/// CSV lines (`;` separated) for saving on-line results: header row and
/// one data row per acquisition.
String onlineCsvHeader(OnlineResult r) =>
    ['time', 'record', for (final q in r.quantities) '${q.name} [${q.unit}]'].join(';');

String onlineCsvRow(OnlineResult r, int record, DateTime t) =>
    [t.toIso8601String(), '$record', for (final q in r.quantities) '${q.value}'].join(';');
