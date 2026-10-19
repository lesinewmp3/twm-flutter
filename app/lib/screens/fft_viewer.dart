import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';
import '../widgets/paths.dart';

/// Spectrum viewer (TWM guide figure 3.33): shows the spectra calculated by
/// the selected algorithm (quantities listed as 'spectrum' in
/// qwtb_list.info), or the live spectrum of the last record.
Future<void> showFftViewer(BuildContext context) => showDialog(
  context: context,
  builder: (_) => AppScope(state: AppScope.read(context), child: const _FftViewer()),
);

class _FftViewer extends StatefulWidget {
  const _FftViewer();
  @override
  State<_FftViewer> createState() => _FftViewerState();
}

class _FftViewerState extends State<_FftViewer> {
  bool _live = false;
  bool _log = true;
  String _alg = '';
  List<ChartSeries> _series = [];
  String _msg = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = AppScope.read(context);
    final session = st.resultsSession;
    if (session.isEmpty) {
      setState(() {
        _live = true;
        _msg = 'No measurement - showing live spectrum.';
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final info = await st.backend.resultsInfo(session);
      _alg = info.lastAlgorithm;
      if (_alg.isEmpty) throw 'No processed results.';
      final list = Info.parse(await st.backend.readText(joinPath(st.settings.octave.octprogPath, 'qwtb_list.info')));
      final sec = list.sectionOrNull(_alg);
      final spec = sec?.textMatrixOrNull('spectrum');
      if (sec == null || spec == null || spec.isEmpty) throw 'Algorithm $_alg does not return a spectrum.';
      final ys = [for (final r in spec) ...r].where((e) => e.isNotEmpty).toList();
      final graphs = sec.textMatrixOrNull('graphs') ?? const [];
      final xs = <String, String>{
        for (final g in graphs)
          if (g.length > 1) g[1]: g[0],
      };
      final vars = {...ys, ...ys.map((y) => xs[y] ?? '').where((e) => e.isNotEmpty)}.toList();
      final cfg = ResultViewConfig(resultId: -1, variables: vars);
      final d = await st.backend.resultData(session, _alg, cfg);
      final series = <ChartSeries>[];
      var k = 0;
      for (final ch in d.channels) {
        for (final y in ys) {
          final q = ch.where((e) => e.name == y);
          if (q.isEmpty) continue;
          final xq = ch.where((e) => e.name == xs[y]);
          final x = xq.isEmpty ? null : xq.first.value;
          series.add(
            ChartSeries(
              '$y [${q.first.tag}]',
              q.first.value,
              x: x != null && x.length == q.first.value.length ? x : null,
              color: chartColors[k++ % chartColors.length],
            ),
          );
        }
      }
      setState(() {
        _series = series;
        _msg = '$_alg - last result of ${dirName(session)}';
      });
    } catch (e) {
      setState(() {
        _live = true;
        _msg = '$e Showing live spectrum.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    var series = _series;
    if (_live) {
      final w = st.lastWaveform;
      series = w == null
          ? []
          : [
              for (var c = 0; c < w.spectra.length; c++)
                ChartSeries('#${c + 1}', w.spectra[c], dx: w.df, color: chartColors[c % chartColors.length]),
            ];
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1100,
        height: 700,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('Spectrum viewer', style: Theme.of(context).textTheme.titleLarge),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('Algorithm spectrum')),
                            ButtonSegment(value: true, label: Text('Live spectrum')),
                          ],
                          selected: {_live},
                          onSelectionChanged: (s) {
                            setState(() => _live = s.first);
                            if (!_live) _load();
                          },
                        ),
                        Check(label: 'Log scale', value: _log, onChanged: (v) => setState(() => _log = v)),
                        if (_busy) const CircularProgressIndicator(),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_msg, style: Theme.of(context).textTheme.bodySmall),
              ),
              Expanded(
                child: series.isEmpty
                    ? const Center(child: Text('No spectrum available.'))
                    : LineChart(series: series, xLabel: 'frequency [Hz]', yLabel: 'amplitude', logY: _log),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
