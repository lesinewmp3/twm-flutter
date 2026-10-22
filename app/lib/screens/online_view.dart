import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../l10n.dart';

/// On-line data processing (TPQA "CVI Data Processing", guide figures
/// 3.61/3.62): grid of measured values with statistics, harmonic graphs
/// and history graph of a selected quantity.
class OnlineView extends StatefulWidget {
  const OnlineView({super.key});
  @override
  State<OnlineView> createState() => _OnlineViewState();
}

class _OnlineViewState extends State<OnlineView> {
  final Map<String, List<double>> _history = {};
  OnlineResult? _last;
  String? _graph;
  int _maxPoints = 500;

  void _collect(OnlineResult r) {
    if (identical(r, _last)) return;
    _last = r;
    for (final q in r.quantities) {
      final h = _history.putIfAbsent(q.name, () => []);
      h.add(q.value);
      if (h.length > _maxPoints) h.removeRange(0, h.length - _maxPoints);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final o = st.settings.online;
    final r = st.lastOnline;
    if (r != null) _collect(r);
    void upd(void Function(OnlineAnalysisConfig c) f) => st.update((s) => f(s.online));
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Check(
                label: tr('On-line processing enabled'),
                value: o.enabled,
                onChanged: (v) => upd((c) => c.enabled = v),
              ),
              Check(
                label: tr('Harmonic analyzer ON'),
                value: o.harmonicAnalyzer,
                onChanged: (v) => upd((c) => c.harmonicAnalyzer = v),
              ),
              NumField(
                label: tr('Harmonic number'),
                value: o.harmonics.toDouble(),
                integer: true,
                min: 1,
                max: 200,
                width: 140,
                onChanged: (v) => upd((c) => c.harmonics = v.round()),
              ),
              Choice<WindowType>(
                label: tr('Window type'),
                value: o.window,
                items: WindowType.values,
                width: 190,
                itemLabel: (w) => w.label,
                onChanged: (v) => upd((c) => c.window = v),
              ),
              Check(label: tr('On/Off statistic'), value: o.statistics, onChanged: (v) => upd((c) => c.statistics = v)),
              Check(
                label: tr('Sag / interruption / transfer analysis'),
                value: o.transferAnalysis,
                onChanged: (v) => upd((c) => c.transferAnalysis = v),
              ),
              if (o.transferAnalysis)
                NumField(
                  label: tr('Event threshold'),
                  unit: '%',
                  value: o.transferThreshold,
                  min: 1,
                  max: 90,
                  width: 140,
                  tooltip: tr('Deviation from the steady waveform that marks an event, % of the peak'),
                  onChanged: (v) => upd((c) => c.transferThreshold = v),
                ),
              NumField(
                label: tr('Average cycles'),
                value: o.averageCycles.toDouble(),
                integer: true,
                min: 2,
                width: 130,
                onChanged: (v) => upd((c) => c.averageCycles = v.round()),
              ),
              NumField(
                label: tr('Max points to display'),
                value: _maxPoints.toDouble(),
                integer: true,
                min: 10,
                width: 170,
                onChanged: (v) => setState(() => _maxPoints = v.round()),
              ),
              OutlinedButton(onPressed: () => setState(_history.clear), child: Text(tr('Clear history'))),
              Check(
                label: tr('Save CVI processed data'),
                value: o.saveResults,
                onChanged: (v) => upd((c) => c.saveResults = v),
              ),
              if (o.saveResults)
                PathField(
                  label: tr('Results file (CSV, appended)'),
                  value: o.resultsFile,
                  backend: st.backend,
                  mode: BrowseMode.saveFile,
                  extensions: const ['.csv'],
                  width: 420,
                  onChanged: (v) => upd((c) => c.resultsFile = v),
                ),
              Text(
                tr(
                  'Quick calculation for watching the measurement: nominal transducer ratios, without calibration '
                  'corrections and uncertainty. Results for a report: the Results page (QWTB algorithms). '
                  'Settings apply to the next measurement start.',
                ),
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
          if (r != null && r.recordTime > r.analyzedTime)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                trf(
                  'Only the first {0} s of the {1} s record are analysed (memory limit): events later in the record '
                  'are not seen here. Use shorter records or a lower sampling rate.',
                  [formatNum(r.analyzedTime), formatNum(r.recordTime)],
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: r == null
                ? Center(child: Text(tr('No on-line results - start a measurement (continuous mode recommended).')))
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: _grid(r, o.statistics)),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_graph != null)
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '${tr('History')}: $_graph',
                                          style: Theme.of(context).textTheme.titleSmall,
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          onPressed: () => setState(() => _graph = null),
                                          icon: const Icon(Icons.close),
                                        ),
                                      ],
                                    ),
                                    Expanded(
                                      child: LineChart(
                                        xLabel: tr('acquisition #'),
                                        yLabel: _graph!,
                                        series: [
                                          ChartSeries(_graph!, _history[_graph] ?? const [], color: chartColors[0]),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            for (final e in r.harmonics.entries)
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '${tr('Harmonics')} ${e.key} (f0 = ${r.f0.isNaN ? '-' : formatNum(r.f0)} ${tr('Hz')})',
                                      style: Theme.of(context).textTheme.labelLarge,
                                    ),
                                    Expanded(
                                      child: LineChart(
                                        xLabel: tr('harmonic #'),
                                        yLabel: e.key.startsWith('i') ? 'A' : 'V',
                                        logY: true,
                                        showLegend: false,
                                        series: [
                                          ChartSeries(
                                            e.key,
                                            e.value,
                                            x0: 1,
                                            color: chartColors[e.key.startsWith('i') ? 1 : 0],
                                            bars: true,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _grid(OnlineResult r, bool stats) {
    final th = Theme.of(context);
    String f(double v) => v.isNaN ? '-' : formatDisplay(v, digits: 8);
    return SingleChildScrollView(
      child: Table(
        border: TableBorder.all(color: th.dividerColor),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          TableRow(
            decoration: BoxDecoration(color: th.colorScheme.surfaceContainerHigh),
            children: [
              for (final h in [
                tr('Quantity'),
                tr('Unit'),
                tr('Value'),
                if (stats) ...[tr('Mean'), tr('Std. dev.'), 'u_A', tr('Error %'), 'N'],
                '',
              ])
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          for (final q in r.quantities)
            TableRow(
              children: [
                _c(trQuantity(q.name), bold: true),
                _c(trUnit(q.unit)),
                _c(f(q.value)),
                if (stats) ...[_c(f(q.mean)), _c(f(q.std)), _c(f(q.uA)), _c(f(q.errorPercent)), _c('${q.count}')],
                IconButton(
                  tooltip: tr('Show graph'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.show_chart, size: 18),
                  onPressed: () => setState(() => _graph = q.name),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _c(String t, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    child: Text(
      t,
      style: TextStyle(fontFamily: 'monospace', fontWeight: bold ? FontWeight.bold : null),
    ),
  );
}
