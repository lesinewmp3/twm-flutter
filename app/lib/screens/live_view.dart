import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../l10n.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';

/// Measurement page: key values, waveforms of the last record, differential
/// voltage (TPQA) and amplitude spectrum (TWM "GUI Update Wave/FFT").
class LiveView extends StatefulWidget {
  const LiveView({super.key});
  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  bool _logSpectrum = true;
  bool _diff = false;
  bool _monitor = true; // live oscilloscope-like view, else the whole record
  int _diffHi = 0, _diffLo = 1;
  final Set<int> _hidden = {};

  static const _tileQuantities = ['RMS', 'f', 'THD', 'P', 'Q', 'PF', 'Event'];

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final w = st.lastWaveform;
    if (w == null && st.live.value == null) return _empty(context, st);
    final n = w?.channels.length ?? st.live.value!.channels.length;
    final hi = _diffHi.clamp(0, n - 1), lo = _diffLo.clamp(0, n - 1);
    final waves = [
      if (w != null)
        for (var c = 0; c < n; c++)
          if (!_hidden.contains(c))
            ChartSeries(_label(w.names, c), w.channels[c], dx: w.ts, color: chartColors[c % chartColors.length]),
    ];
    final spectra = [
      if (w != null)
        for (var c = 0; c < w.spectra.length; c++)
          if (!_hidden.contains(c))
            ChartSeries(_label(w.names, c), w.spectra[c], dx: w.df, color: chartColors[c % chartColors.length]),
    ];
    final monitor = _monitor && st.live.value != null;
    final tiles = _tiles(st.lastOnline);
    return LayoutBuilder(
      builder: (context, box) {
        final chartH = (box.maxHeight - (tiles.isEmpty ? 120 : 210)).clamp(260.0, 2000.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (tiles.isNotEmpty) ...[Wrap(spacing: 12, runSpacing: 12, children: tiles), const SizedBox(height: 16)],
              Panel(
                title: monitor
                    ? tr('Waveforms')
                    : '${tr('Waveforms')} · ${tr('record')} ${w?.record ?? st.live.value!.record}',
                actions: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [
                      ButtonSegment(value: true, label: Text(tr('Monitor')), icon: const Icon(Icons.monitor_heart_outlined, size: 18)),
                      ButtonSegment(value: false, label: Text(tr('Whole record')), icon: const Icon(Icons.timeline, size: 18)),
                    ],
                    selected: {_monitor},
                    onSelectionChanged: (v) => setState(() => _monitor = v.first),
                  ),
                  if (_monitor) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: tr('Monitor window (applies at the next start)'),
                      child: Choice<double>(
                        label: tr('Window'),
                        value: st.settings.online.monitorWindowMs,
                        items: const [20, 40, 80, 200, 1000],
                        width: 110,
                        itemLabel: (v) => '${v.round()} ${tr('ms')}',
                        onChanged: (v) => st.update((s) => s.online.monitorWindowMs = v),
                      ),
                    ),
                  ],
                  for (var c = 0; c < n; c++)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: FilterChip(
                        label: Text('#${c + 1}'),
                        tooltip: () {
                          final names = w?.names ?? st.live.value?.names ?? const <String>[];
                          return c < names.length ? names[c] : null;
                        }(),
                        selected: !_hidden.contains(c),
                        onSelected: (v) => setState(() => v ? _hidden.remove(c) : _hidden.add(c)),
                      ),
                    ),
                ],
                child: SizedBox(
                  height: chartH * (_diff && n > 1 ? 0.5 : 0.55),
                  child: monitor
                      ? ValueListenableBuilder<LiveEvent?>(
                          valueListenable: st.live,
                          builder: (context, lv, _) => _monitorChart(lv!),
                        )
                      : LineChart(series: waves, xLabel: tr('time [s]'), yLabel: tr('voltage [V]')),
                ),
              ),
              const SizedBox(height: 16),
              if (n > 1) ...[
                Panel(
                  title: tr('Differential voltage (High - Low)'),
                  actions: [
                    Switch(value: _diff, onChanged: (v) => setState(() => _diff = v)),
                    if (_diff) ...[
                      const SizedBox(width: 8),
                      Choice<int>(
                        label: tr('High'),
                        value: hi,
                        items: [for (var c = 0; c < n; c++) c],
                        width: 90,
                        itemLabel: (c) => '#${c + 1}',
                        onChanged: (v) => setState(() => _diffHi = v),
                      ),
                      const SizedBox(width: 8),
                      Choice<int>(
                        label: tr('Low'),
                        value: lo,
                        items: [for (var c = 0; c < n; c++) c],
                        width: 90,
                        itemLabel: (c) => '#${c + 1}',
                        onChanged: (v) => setState(() => _diffLo = v),
                      ),
                    ],
                  ],
                  child: !_diff
                      ? const SizedBox.shrink()
                      : SizedBox(
                          height: chartH * 0.4,
                          child: w == null
                              ? const SizedBox.shrink()
                              : LineChart(
                                  xLabel: tr('time [s]'),
                                  yLabel: 'Vh - Vl [V]',
                                  series: [
                                    ChartSeries(
                                      '#${hi + 1} - #${lo + 1}',
                                      [
                                        for (var i = 0; i < w.channels[hi].length; i++)
                                          w.channels[hi][i] - w.channels[lo][i],
                                      ],
                                      dx: w.ts,
                                      color: chartColors[4],
                                    ),
                                  ],
                                ),
                        ),
                ),
                const SizedBox(height: 16),
              ],
              if (spectra.isNotEmpty)
                Panel(
                  title: tr('Amplitude spectrum'),
                  actions: [
                    Text(tr('log scale')),
                    Switch(value: _logSpectrum, onChanged: (v) => setState(() => _logSpectrum = v)),
                  ],
                  child: SizedBox(
                    height: chartH * 0.55,
                    child: LineChart(
                      series: spectra,
                      xLabel: tr('frequency [Hz]'),
                      yLabel: tr('amplitude [V]'),
                      logY: _logSpectrum,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Chart: mouse wheel - zoom time axis, Shift + wheel - zoom amplitude, drag - move, double click - reset.',
                ),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _tiles(OnlineResult? r) {
    if (r == null) return const [];
    final out = <Widget>[];
    for (final q in r.quantities) {
      final kind = q.name.split(' ').first;
      if (!_tileQuantities.contains(kind)) continue;
      if (q.name.startsWith('Event') && !q.name.startsWith('Event duration')) continue;
      out.add(StatTile(trQuantity(q.name), formatDisplay(q.value), q.unit));
      if (out.length >= 10) break;
    }
    return out;
  }

  Widget _empty(BuildContext context, AppState st) {
    final t = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 64, color: t.colorScheme.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(tr('No measurement yet'), style: t.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              st.backend.features.hardware
                  ? tr('Configure the digitizer and the measurement, then press Start.')
                  : tr(
                      'This browser version uses a simulated digitizer: set the signal in Digitizer, then press Start.',
                    ),
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// Live monitor: newest samples aligned to the trigger, stable axes.
  Widget _monitorChart(LiveEvent lv) {
    final series = [
      for (var c = 0; c < lv.channels.length; c++)
        if (!_hidden.contains(c))
          ChartSeries(
            _label(lv.names, c),
            lv.channels[c],
            x0: lv.x0 * 1000,
            dx: lv.dx * 1000,
            color: chartColors[c % chartColors.length],
          ),
    ];
    return Stack(
      children: [
        Positioned.fill(
          child: LineChart(
            series: series,
            xLabel: tr('time [ms]'),
            yLabel: tr('voltage [V]'),
            stableY: true,
            fixedX: (0, lv.span * 1000),
          ),
        ),
        Positioned(
          right: 18,
          top: 12,
          child: Text(
            '${tr('record')} ${lv.record} · ${lv.triggered ? tr('sync') : tr('auto')}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  static String _label(List<String> names, int c) {
    final n = c < names.length ? names[c] : '';
    return '#${c + 1}${n.isEmpty ? '' : ' $n'}';
  }
}
