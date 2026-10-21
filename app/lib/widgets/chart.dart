import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

/// One data series of [LineChart]: y values at x = x0 + i*dx, or explicit x.
class ChartSeries {
  final String name;
  final List<double> y;
  final List<double>? x;
  final double x0;
  final double dx;
  final Color color;
  final bool bars; // stem/bar plot (harmonics)

  const ChartSeries(this.name, this.y, {this.x, this.x0 = 0, this.dx = 1, required this.color, this.bars = false});

  int get length => y.length;
  double xAt(int i) => x != null ? x![i] : x0 + i * dx;
}

/// Palette for channels (distinct also in dark theme).
const chartColors = [
  Color(0xFF1F77B4),
  Color(0xFFD62728),
  Color(0xFF2CA02C),
  Color(0xFFFF7F0E),
  Color(0xFF9467BD),
  Color(0xFF8C564B),
  Color(0xFFE377C2),
  Color(0xFF17BECF),
];

/// Simple interactive XY line chart (LabVIEW waveform graph replacement):
/// autoscale, wheel zoom (x; with Shift y), drag pan, double click reset,
/// hover cursor read-out, optional log y axis.
class LineChart extends StatefulWidget {
  final List<ChartSeries> series;
  final String xLabel;
  final String yLabel;
  final bool logY;
  final bool showLegend;

  /// Oscilloscope-like amplitude axis for live data: grows at once, shrinks
  /// only when the signal stayed much smaller for a while, nice limits.
  final bool stableY;

  /// Fixed time axis (live monitor window) instead of the data range.
  final (double, double)? fixedX;

  const LineChart({
    super.key,
    required this.series,
    this.xLabel = '',
    this.yLabel = '',
    this.logY = false,
    this.showLegend = true,
    this.stableY = false,
    this.fixedX,
  });

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  Rect? _view; // visible data range (null = autoscale)
  Offset? _hover;
  double? _yLo, _yHi; // stable amplitude axis
  DateTime? _smallSince;

  Rect _autoBounds() {
    var r = _dataBounds();
    final fx = widget.fixedX;
    if (fx != null && fx.$2 > fx.$1) r = Rect.fromLTRB(fx.$1, r.top, fx.$2, r.bottom);
    if (!widget.stableY || widget.logY) return r;
    final lo = r.top, hi = r.bottom; // top = minimum
    final now = DateTime.now();
    if (_yLo == null || lo < _yLo! || hi > _yHi!) {
      final t = niceTicks(lo, hi, 6);
      final step = t.length > 1 ? t[1] - t[0] : (hi - lo);
      _yLo = step > 0 ? (lo / step).floorToDouble() * step : lo;
      _yHi = step > 0 ? (hi / step).ceilToDouble() * step : hi;
      _smallSince = null;
    } else if (hi - lo < 0.45 * (_yHi! - _yLo!)) {
      _smallSince ??= now;
      if (now.difference(_smallSince!) > const Duration(milliseconds: 1500)) {
        _yLo = null; // re-fit on the next frame
        _smallSince = null;
      }
    } else {
      _smallSince = null;
    }
    return _yLo == null ? r : Rect.fromLTRB(r.left, _yLo!, r.right, _yHi!);
  }

  Rect _dataBounds() {
    var xmin = double.infinity, xmax = -double.infinity;
    var ymin = double.infinity, ymax = -double.infinity;
    for (final s in widget.series) {
      for (var i = 0; i < s.length; i++) {
        final x = s.xAt(i);
        var y = s.y[i];
        if (!y.isFinite || !x.isFinite) continue;
        if (widget.logY) {
          if (y <= 0) continue;
          y = math.log(y) / math.ln10;
        }
        xmin = math.min(xmin, x);
        xmax = math.max(xmax, x);
        ymin = math.min(ymin, y);
        ymax = math.max(ymax, y);
      }
      if (s.bars && !widget.logY) ymin = math.min(ymin, 0);
    }
    if (!xmin.isFinite) return const Rect.fromLTRB(0, -1, 1, 1);
    if (xmax == xmin) xmax = xmin + 1;
    if (widget.series.any((s) => s.bars)) {
      // keep the edge bars visible
      final mx = (xmax - xmin) * 0.03;
      xmin -= mx;
      xmax += mx;
    }
    if (ymax == ymin) {
      ymax += ymax.abs() * 0.1 + 1e-12;
      ymin -= ymin.abs() * 0.1 + 1e-12;
    }
    final my = (ymax - ymin) * 0.05;
    return Rect.fromLTRB(xmin, ymin - my, xmax, ymax + my);
  }

  @override
  void didUpdateWidget(LineChart old) {
    super.didUpdateWidget(old);
    if (old.logY != widget.logY) _view = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final bounds = _view ?? _autoBounds();
        _ChartPainter painter(bool hoverLayer) => _ChartPainter(
          series: widget.series,
          view: bounds,
          logY: widget.logY,
          xLabel: widget.xLabel,
          yLabel: widget.yLabel,
          hover: _hover,
          fg: theme.colorScheme.onSurface,
          grid: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          bg: theme.colorScheme.surfaceContainerLowest,
          hoverLayer: hoverLayer,
        );
        return Column(
          children: [
            Expanded(
              child: Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    final plot = _ChartPainter.plotRect(c.biggest);
                    final f = e.scrollDelta.dy > 0 ? 1.2 : 1 / 1.2;
                    final shift = HardwareKeyboard.instance.isShiftPressed;
                    final b = bounds;
                    final px = ((e.localPosition.dx - plot.left) / plot.width).clamp(0.0, 1.0);
                    final py = ((plot.bottom - e.localPosition.dy) / plot.height).clamp(0.0, 1.0);
                    setState(() {
                      if (shift) {
                        final cy = b.top + py * b.height;
                        _view = Rect.fromLTRB(b.left, cy - (cy - b.top) * f, b.right, cy + (b.bottom - cy) * f);
                      } else {
                        final cx = b.left + px * b.width;
                        _view = Rect.fromLTRB(cx - (cx - b.left) * f, b.top, cx + (b.right - cx) * f, b.bottom);
                      }
                    });
                  }
                },
                child: MouseRegion(
                  onHover: (e) => setState(() => _hover = e.localPosition),
                  onExit: (_) => setState(() => _hover = null),
                  child: GestureDetector(
                    onDoubleTap: () => setState(() => _view = null),
                    onPanUpdate: (d) {
                      final plot = _ChartPainter.plotRect(c.biggest);
                      final b = bounds;
                      final dx = -d.delta.dx / plot.width * b.width;
                      final dy = d.delta.dy / plot.height * b.height;
                      setState(() => _view = b.translate(dx, dy));
                    },
                    // data layer is kept (and rasterized) apart from the hover
                    // cursor: moving the mouse repaints only the cursor
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(child: CustomPaint(painter: painter(false), size: Size.infinite)),
                        CustomPaint(painter: painter(true), size: Size.infinite),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (widget.showLegend && widget.series.length > 1)
              Wrap(
                spacing: 16,
                children: [
                  for (final s in widget.series)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 14, height: 3, color: s.color),
                        const SizedBox(width: 4),
                        Text(s.name, style: theme.textTheme.bodySmall),
                      ],
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<ChartSeries> series;
  final Rect view; // left/right = x range, top/bottom = y min/max
  final bool logY;
  final String xLabel, yLabel;
  final Offset? hover;
  final Color fg, grid, bg;

  /// Paints only the hover cursor and read-out (else everything else).
  final bool hoverLayer;

  _ChartPainter({
    required this.series,
    required this.view,
    required this.logY,
    required this.xLabel,
    required this.yLabel,
    required this.hover,
    required this.fg,
    required this.grid,
    required this.bg,
    this.hoverLayer = false,
  });

  static Rect plotRect(Size s) => Rect.fromLTRB(64, 8, s.width - 12, s.height - 36);

  double _ty(double y) => logY ? (y > 0 ? math.log(y) / math.ln10 : double.nan) : y;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotRect(size);
    if (plot.width <= 10 || plot.height <= 10) return;
    final xmin = view.left, xmax = view.right, ymin = view.top, ymax = view.bottom;
    final ts = TextStyle(color: fg, fontSize: 10);
    if (hoverLayer) {
      _paintHover(canvas, plot, xmin, xmax, ts);
      return;
    }
    canvas.drawRect(plot, Paint()..color = bg);
    double px(double x) => plot.left + (x - xmin) / (xmax - xmin) * plot.width;
    double py(double y) => plot.bottom - (y - ymin) / (ymax - ymin) * plot.height;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // x ticks
    for (final t in niceTicks(xmin, xmax, (plot.width / 90).floor().clamp(2, 12))) {
      final x = px(t);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      _text(canvas, formatTick(t), Offset(x, plot.bottom + 3), ts, center: true);
    }
    // y ticks
    for (final t in niceTicks(ymin, ymax, (plot.height / 40).floor().clamp(2, 10))) {
      final y = py(t);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(
        canvas,
        logY ? formatTick(math.pow(10, t).toDouble()) : formatTick(t),
        Offset(plot.left - 4, y - 6),
        ts,
        right: true,
      );
    }
    _text(canvas, xLabel, Offset(plot.center.dx, size.height - 14), ts, center: true);
    if (yLabel.isNotEmpty) {
      canvas.save();
      canvas.translate(2, plot.center.dy);
      canvas.rotate(-math.pi / 2);
      _text(canvas, yLabel, Offset.zero, ts, center: true);
      canvas.restore();
    }

    canvas.save();
    canvas.clipRect(plot);
    for (final s in series) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.bars ? 3 : 1.2
        ..style = PaintingStyle.stroke;
      if (s.bars) {
        final y0 = py(logY ? ymin : 0);
        for (var i = 0; i < s.length; i++) {
          final y = _ty(s.y[i]);
          if (!y.isFinite) continue;
          final x = px(s.xAt(i));
          canvas.drawLine(Offset(x, y0), Offset(x, py(y)), paint);
        }
        continue;
      }
      // min/max decimation per pixel column for long series
      final path = Path();
      var started = false;
      final n = s.length;
      final perPx = n / plot.width;
      if (perPx > 2 && s.x == null) {
        final i0 = ((xmin - s.x0) / s.dx).floor().clamp(0, n - 1);
        final i1 = ((xmax - s.x0) / s.dx).ceil().clamp(0, n - 1);
        final cols = plot.width.floor();
        final span = (i1 - i0 + 1) / cols;
        for (var c = 0; c < cols; c++) {
          final a = i0 + (c * span).floor();
          final b = math.min(i1, i0 + ((c + 1) * span).floor());
          var lo = double.infinity, hi = -double.infinity;
          for (var i = a; i <= b; i++) {
            final y = _ty(s.y[i]);
            if (!y.isFinite) continue;
            lo = math.min(lo, y);
            hi = math.max(hi, y);
          }
          if (!lo.isFinite) continue;
          final x = plot.left + c + 0.5;
          if (!started) {
            path.moveTo(x, py(lo));
            started = true;
          } else {
            path.lineTo(x, py(lo));
          }
          path.lineTo(x, py(hi));
        }
      } else {
        for (var i = 0; i < n; i++) {
          final y = _ty(s.y[i]);
          if (!y.isFinite) {
            started = false;
            continue;
          }
          final o = Offset(px(s.xAt(i)), py(y));
          if (!started) {
            path.moveTo(o.dx, o.dy);
            started = true;
          } else {
            path.lineTo(o.dx, o.dy);
          }
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
    canvas.drawRect(
      plot,
      Paint()
        ..color = fg.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke,
    );

  }

  void _paintHover(Canvas canvas, Rect plot, double xmin, double xmax, TextStyle ts) {
    final h = hover;
    if (h != null && plot.contains(h)) {
      final xv = xmin + (h.dx - plot.left) / plot.width * (xmax - xmin);
      canvas.drawLine(Offset(h.dx, plot.top), Offset(h.dx, plot.bottom), Paint()..color = fg.withValues(alpha: 0.4));
      final lines = <String>['x = ${formatValue(xv)}'];
      for (final s in series) {
        if (s.length == 0) continue;
        int i;
        if (s.x == null) {
          i = ((xv - s.x0) / s.dx).round().clamp(0, s.length - 1);
        } else {
          i = 0;
          var best = double.infinity;
          for (var k = 0; k < s.length; k++) {
            final d = (s.x![k] - xv).abs();
            if (d < best) {
              best = d;
              i = k;
            }
          }
        }
        lines.add('${s.name}: ${formatValue(s.y[i])}');
      }
      final tp = TextPainter(
        text: TextSpan(text: lines.join('\n'), style: ts),
        textDirection: TextDirection.ltr,
      )..layout();
      var o = h + const Offset(10, 10);
      if (o.dx + tp.width + 8 > plot.right) o = Offset(h.dx - tp.width - 18, o.dy);
      if (o.dy + tp.height + 8 > plot.bottom) o = Offset(o.dx, h.dy - tp.height - 18);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx - 4, o.dy - 4, tp.width + 8, tp.height + 8),
          const Radius.circular(4),
        ),
        Paint()..color = bg.withValues(alpha: 0.9),
      );
      tp.paint(canvas, o);
    }
  }

  void _text(Canvas c, String s, Offset o, TextStyle st, {bool center = false, bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    var off = o;
    if (center) off = Offset(o.dx - tp.width / 2, o.dy);
    if (right) off = Offset(o.dx - tp.width, o.dy);
    tp.paint(c, off);
  }

  @override
  bool shouldRepaint(_ChartPainter old) {
    final data =
        !identical(old.series, series) ||
        old.view != view ||
        old.logY != logY ||
        old.xLabel != xLabel ||
        old.yLabel != yLabel ||
        old.fg != fg ||
        old.grid != grid ||
        old.bg != bg;
    return hoverLayer ? data || old.hover != hover : data;
  }
}

/// "Nice" tick values between [a] and [b].
List<double> niceTicks(double a, double b, int count) {
  if (!(b > a)) return [a];
  final raw = (b - a) / count;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step =
      (norm < 1.5
          ? 1
          : norm < 3
          ? 2
          : norm < 7
          ? 5
          : 10) *
      mag;
  final out = <double>[];
  for (var t = (a / step).ceil() * step; t <= b + step * 1e-9; t += step) {
    out.add((t / step).round() * step);
  }
  return out;
}

String formatTick(double v) {
  if (v == 0) return '0';
  final a = v.abs();
  if (a >= 1e5 || a < 1e-3) return v.toStringAsExponential(1);
  if (a >= 100) return v.toStringAsFixed(0);
  if (a >= 1) return _trim(v.toStringAsFixed(2));
  return _trim(v.toStringAsPrecision(3));
}

String formatValue(double v) {
  if (!v.isFinite) return '$v';
  final a = v.abs();
  if (a != 0 && (a >= 1e6 || a < 1e-4)) return v.toStringAsExponential(5);
  return _trim(v.toStringAsPrecision(7));
}

String _trim(String s) =>
    s.contains('.') && !s.contains('e') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
