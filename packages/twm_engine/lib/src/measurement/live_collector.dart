import 'dart:math' as math;
import 'dart:typed_data';

import '../digitizer/virtual_digitizer.dart';

/// Collects the display and analysis data of one record while its blocks
/// stream in, without keeping the whole record in memory:
///
/// - preview: min/max envelope, two points per bucket in time order. Plain
///   decimation (every k-th sample) aliases fast content (switching ripple)
///   into false slow waves; the envelope shows it as a band, like a scope.
/// - analysis: the first [fullLimit] samples at full rate.
///
/// Works on raw codes: gains/offsets may arrive only with the last block,
/// scaling is done by [preview] and [full].
class LiveCollector {
  final int channels;
  final int total;
  final int previewPoints;
  final int fullLimit;

  /// Samples per preview bucket (1 = raw samples are shown).
  late final int bucket;
  late final int _buckets;
  final List<Int32List> _full;
  // per bucket extremes and their positions (to output them in time order)
  late final List<Int32List> _min, _max, _minAt, _maxAt;
  int _received = 0;

  LiveCollector({required this.channels, required this.total, this.previewPoints = 4000, this.fullLimit = 2000000})
    : _full = [for (var c = 0; c < channels; c++) Int32List(math.min(total, fullLimit))] {
    final half = math.max(1, previewPoints ~/ 2);
    bucket = total <= previewPoints ? 1 : (total / half).ceil();
    _buckets = bucket == 1 ? 0 : (total / bucket).ceil();
    Int32List mk(int v) => Int32List(_buckets)..fillRange(0, _buckets, v);
    _min = [for (var c = 0; c < channels; c++) mk(0x7fffffff)];
    _max = [for (var c = 0; c < channels; c++) mk(-0x80000000)];
    _minAt = [for (var c = 0; c < channels; c++) Int32List(_buckets)];
    _maxAt = [for (var c = 0; c < channels; c++) Int32List(_buckets)];
  }

  /// Samples per channel received so far.
  int get received => _received;

  void add(DataPacket p) {
    final n = math.min(p.count, total - _received);
    if (n <= 0) return;
    final s = p.samples;
    final ch = p.channels;
    final fullEnd = math.min(fullLimit, total);
    for (var c = 0; c < channels && c < ch; c++) {
      final full = _full[c];
      for (var i = 0, k = _received; i < n && k < fullEnd; i++, k++) {
        full[k] = s[i * ch + c];
      }
      if (bucket == 1) continue;
      final mn = _min[c], mx = _max[c], mnAt = _minAt[c], mxAt = _maxAt[c];
      for (var i = 0; i < n; i++) {
        final k = _received + i;
        final b = k ~/ bucket;
        final v = s[i * ch + c];
        if (v < mn[b]) {
          mn[b] = v;
          mnAt[b] = k;
        }
        if (v > mx[b]) {
          mx[b] = v;
          mxAt[b] = k;
        }
      }
    }
    _received += n;
  }

  /// Scaled preview channels and their sample period.
  (List<Float64List>, double) preview(List<double> gains, List<double> offsets, double ts) {
    if (bucket == 1) return (full(gains, offsets), ts);
    final nb = math.min(_buckets, (_received / bucket).ceil());
    final out = <Float64List>[];
    for (var c = 0; c < channels; c++) {
      final y = Float64List(2 * nb);
      final g = c < gains.length ? gains[c] : 1.0, o = c < offsets.length ? offsets[c] : 0.0;
      final mn = _min[c], mx = _max[c], mnAt = _minAt[c], mxAt = _maxAt[c];
      for (var b = 0; b < nb; b++) {
        final minFirst = mnAt[b] <= mxAt[b];
        y[2 * b] = (minFirst ? mn[b] : mx[b]) * g + o;
        y[2 * b + 1] = (minFirst ? mx[b] : mn[b]) * g + o;
      }
      out.add(y);
    }
    // two points per bucket
    return (out, ts * bucket / 2);
  }

  /// Scaled analysis data (first min(received, [fullLimit]) samples).
  List<Float64List> full(List<double> gains, List<double> offsets) {
    final n = math.min(_received, _full.isEmpty ? 0 : _full.first.length);
    return [
      for (var c = 0; c < channels; c++)
        () {
          final g = c < gains.length ? gains[c] : 1.0, o = c < offsets.length ? offsets[c] : 0.0;
          final src = _full[c];
          final y = Float64List(n);
          for (var i = 0; i < n; i++) {
            y[i] = src[i] * g + o;
          }
          return y;
        }(),
    ];
  }

  /// True if the analysis data is only a part of the record.
  bool get truncated => total > fullLimit;
}
