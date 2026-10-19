import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';

/// Live view of the last acquired record: waveforms, differential voltage
/// (TPQA "Differential Sampled Voltage") and amplitude spectrum
/// ("GUI Update Wave" / "GUI Update FFT" of TWM).
class LiveView extends StatefulWidget {
  const LiveView({super.key});
  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  bool _logSpectrum = true;
  bool _diff = false;
  int _diffHi = 0, _diffLo = 1;
  final Set<int> _hidden = {};

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final w = st.lastWaveform;
    if (w == null) {
      return const Center(child: Text('No data yet - start a measurement.'));
    }
    final n = w.channels.length;
    final waves = [
      for (var c = 0; c < n; c++)
        if (!_hidden.contains(c))
          ChartSeries(_label(w, c), w.channels[c], dx: w.ts, color: chartColors[c % chartColors.length]),
    ];
    final spectra = [
      for (var c = 0; c < w.spectra.length; c++)
        if (!_hidden.contains(c))
          ChartSeries(_label(w, c), w.spectra[c], dx: w.df, color: chartColors[c % chartColors.length]),
    ];
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Record ${w.record}', style: Theme.of(context).textTheme.titleSmall),
              for (var c = 0; c < n; c++)
                FilterChip(
                  label: Text(_label(w, c)),
                  selected: !_hidden.contains(c),
                  onSelected: (v) => setState(() => v ? _hidden.remove(c) : _hidden.add(c)),
                ),
              const SizedBox(width: 16),
              Check(label: 'Differential (High - Low)', value: _diff, onChanged: (v) => setState(() => _diff = v)),
              if (_diff && n > 1) ...[
                Choice<int>(
                  label: 'High',
                  value: _diffHi.clamp(0, n - 1),
                  items: [for (var c = 0; c < n; c++) c],
                  width: 90,
                  itemLabel: (c) => '#${c + 1}',
                  onChanged: (v) => setState(() => _diffHi = v),
                ),
                Choice<int>(
                  label: 'Low',
                  value: _diffLo.clamp(0, n - 1),
                  items: [for (var c = 0; c < n; c++) c],
                  width: 90,
                  itemLabel: (c) => '#${c + 1}',
                  onChanged: (v) => setState(() => _diffLo = v),
                ),
              ],
              Check(label: 'Log spectrum', value: _logSpectrum, onChanged: (v) => setState(() => _logSpectrum = v)),
              const Text(
                'wheel: zoom x, shift+wheel: zoom y, drag: pan, double click: reset',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
          Expanded(
            flex: 3,
            child: LineChart(series: waves, xLabel: 'time [s]', yLabel: 'voltage [V]'),
          ),
          if (_diff && n > 1)
            Expanded(
              flex: 2,
              child: LineChart(
                xLabel: 'time [s]',
                yLabel: 'Vh - Vl [V]',
                series: [
                  ChartSeries(
                    '#${_diffHi + 1} - #${_diffLo + 1}',
                    [
                      for (var i = 0; i < w.channels[_diffHi.clamp(0, n - 1)].length; i++)
                        w.channels[_diffHi.clamp(0, n - 1)][i] - w.channels[_diffLo.clamp(0, n - 1)][i],
                    ],
                    dx: w.ts,
                    color: chartColors[4],
                  ),
                ],
              ),
            ),
          if (spectra.isNotEmpty)
            Expanded(
              flex: 3,
              child: LineChart(series: spectra, xLabel: 'frequency [Hz]', yLabel: 'amplitude [V]', logY: _logSpectrum),
            ),
        ],
      ),
    );
  }

  static String _label(WaveformEvent w, int c) {
    final n = c < w.names.length ? w.names[c] : '';
    return '#${c + 1}${n.isEmpty ? '' : ' $n'}';
  }
}
