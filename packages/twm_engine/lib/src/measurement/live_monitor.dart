import 'dart:math' as math;
import 'dart:typed_data';

import '../digitizer/virtual_digitizer.dart';

/// One frame of the oscilloscope-like live view.
class LiveFrame {
  /// Scaled samples per channel (min/max envelope when the window is long).
  final List<Float64List> channels;

  /// Time step of [channels] and time of their first point relative to the
  /// trigger crossing [s] (0 <= x0 < sample period when triggered).
  final double dx;
  final double x0;

  /// Window length [s].
  final double span;
  final bool triggered;
  const LiveFrame(this.channels, this.dx, this.x0, this.span, this.triggered);
}

/// Live view of the samples being acquired: keeps the newest samples in a
/// ring buffer and returns a window starting at a rising crossing of the
/// reference channel (software trigger with hysteresis and sub-sample
/// interpolation), so successive frames stand still on the screen like on
/// an oscilloscope. Without a trigger (DC, noise only, record shorter than a
/// period) the newest window is returned ("auto" mode).
class LiveMonitor {
  final int channels;

  /// Window length [samples].
  final int window;
  final int maxPoints;
  final int refChannel;
  late final int _cap;
  late final List<Int32List> _ring;
  int _written = 0;

  LiveMonitor({required this.channels, required int window, this.maxPoints = 2000, this.refChannel = 0})
    : window = math.max(2, window) {
    // two windows: a trigger point always has a full window after it
    _cap = math.max(2 * this.window, 64);
    _ring = [for (var c = 0; c < channels; c++) Int32List(_cap)];
  }

  int get available => math.min(_written, _cap);

  /// A whole window was acquired; the buffer is full (two windows).
  bool get hasWindow => _written >= window;
  bool get full => _written >= _cap;

  void add(DataPacket p) {
    final ch = math.min(channels, p.channels);
    final n = p.count;
    final s = p.samples;
    // only the newest _cap samples of a big packet matter
    final skip = math.max(0, n - _cap);
    for (var c = 0; c < ch; c++) {
      final r = _ring[c];
      var w = (_written + skip) % _cap;
      for (var i = skip; i < n; i++) {
        r[w] = s[i * p.channels + c];
        if (++w == _cap) w = 0;
      }
    }
    _written += n;
  }

  /// The newest [n] samples of channel [c] in time order (two block copies
  /// from the ring, no per sample index arithmetic).
  Int32List _latest(int c, int n) {
    final out = Int32List(n);
    final r = _ring[c];
    final from = (_written - n) % _cap;
    final first = math.min(n, _cap - from);
    out.setRange(0, first, r, from);
    if (first < n) out.setRange(first, n, r, 0);
    return out;
  }

  /// Current frame, scaled by the channel [gains]/[offsets], sample period [ts].
  LiveFrame? frame(List<double> gains, List<double> offsets, double ts) {
    final n = available;
    if (n < 2) return null;
    final w = math.min(window, n);
    final x = _latest(refChannel.clamp(0, channels - 1), n);

    // trigger level and hysteresis from the newest window (strided scan)
    var lo = 0x7fffffff, hi = -0x80000000;
    final step = math.max(1, w ~/ 4096);
    for (var i = n - w; i < n; i += step) {
      final v = x[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    var start = n - w;
    var x0 = 0.0;
    var triggered = false;
    if (hi - lo >= 8) {
      final level = (lo + hi) / 2, hyst = 0.05 * (hi - lo);
      // newest rising crossing that still has a full window after it
      for (var t = n - w; t >= 1; t--) {
        final a = x[t - 1], b = x[t];
        if (a < level && b >= level) {
          // armed: the signal was below the hysteresis band before (not noise)
          var armed = false;
          for (var k = t - 1; k >= math.max(0, t - w); k--) {
            final v = x[k];
            if (v < level - hyst) {
              armed = true;
              break;
            }
            if (v > level + hyst) break;
          }
          if (!armed) continue;
          start = t;
          // first sample time after the interpolated crossing
          x0 = (1 - (level - a) / (b - a)) * ts;
          triggered = true;
          break;
        }
      }
    }

    // output: raw samples or min/max envelope
    final half = math.max(1, maxPoints ~/ 2);
    final bucket = w <= maxPoints ? 1 : (w / half).ceil();
    final out = <Float64List>[];
    for (var c = 0; c < channels; c++) {
      final r = c == refChannel.clamp(0, channels - 1) ? x : _latest(c, n);
      final g = c < gains.length ? gains[c] : 1.0, o = c < offsets.length ? offsets[c] : 0.0;
      if (bucket == 1) {
        final y = Float64List(w);
        for (var i = 0; i < w; i++) {
          y[i] = r[start + i] * g + o;
        }
        out.add(y);
      } else {
        final nb = (w / bucket).ceil();
        final y = Float64List(2 * nb);
        for (var b = 0; b < nb; b++) {
          final a = start + b * bucket, e = math.min(start + w, a + bucket);
          var mn = r[a], mx = mn, mnAt = a, mxAt = a;
          for (var i = a + 1; i < e; i++) {
            final v = r[i];
            if (v < mn) {
              mn = v;
              mnAt = i;
            }
            if (v > mx) {
              mx = v;
              mxAt = i;
            }
          }
          y[2 * b] = (mnAt <= mxAt ? mn : mx) * g + o;
          y[2 * b + 1] = (mnAt <= mxAt ? mx : mn) * g + o;
        }
        out.add(y);
      }
    }
    return LiveFrame(out, bucket == 1 ? ts : ts * bucket / 2, x0, w * ts, triggered);
  }
}
