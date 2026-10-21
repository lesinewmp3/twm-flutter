import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/paths.dart';
import '../l10n.dart';

enum _MeasSel { none, current, file }

/// QWTB results viewer (TWM guide figure 3.34, TPQA "TWM-Result Viewer").
class ResultsView extends StatefulWidget {
  const ResultsView({super.key});
  @override
  State<ResultsView> createState() => _ResultsViewState();
}

class _ResultsViewState extends State<ResultsView> {
  _MeasSel _sel = _MeasSel.current;
  String _algorithm = '';
  ResultsInfo _info = ResultsInfo.empty;
  ResultsTable _table = ResultsTable.empty;
  String _error = '';
  bool _busy = false;
  int _row = -1;
  int _lastVersion = -1;
  String _lastSession = '';
  Timer? _debounce;
  bool _pending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final st = AppScope.of(context);
    if (st.resultsVersion != _lastVersion || st.resultsSession != _lastSession) {
      _lastVersion = st.resultsVersion;
      final newSession = st.resultsSession != _lastSession;
      _lastSession = st.resultsSession;
      _schedule(reloadInfo: true, resetAlg: newSession);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule({bool reloadInfo = false, bool resetAlg = false}) {
    if (resetAlg) _algorithm = '';
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _refresh(reloadInfo: reloadInfo));
  }

  Future<void> _refresh({bool reloadInfo = false}) async {
    if (!mounted) return;
    final st = AppScope.read(context);
    final session = st.resultsSession;
    if (_sel == _MeasSel.none || session.isEmpty || !st.viewerEnabled) {
      setState(() {
        _info = ResultsInfo.empty;
        _table = ResultsTable.empty;
      });
      return;
    }
    if (_busy) {
      _pending = true;
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (reloadInfo || _info.algorithms.isEmpty) {
        _info = await st.backend.resultsInfo(session, algorithm: _algorithm);
        if (_algorithm.isEmpty || !_info.algorithms.contains(_algorithm)) _algorithm = _info.lastAlgorithm;
        if (_info.exists && _algorithm.isNotEmpty) {
          _info = await st.backend.resultsInfo(session, algorithm: _algorithm);
        }
      }
      if (_info.exists && _algorithm.isNotEmpty) {
        final cfg = st.settings.resultView;
        cfg.variables.removeWhere((v) => !_info.variables.contains(v));
        _table = await st.backend.results(session, _algorithm, cfg);
      } else {
        _table = ResultsTable.empty;
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_pending) {
          _pending = false;
          _schedule();
        }
      }
    }
  }

  void _cfg(void Function(ResultViewConfig c) f) {
    AppScope.read(context).update((s) => f(s.resultView));
    _schedule();
  }

  Future<void> _rowMenu(Offset pos, int row) async {
    final st = AppScope.read(context);
    final a = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(value: 'graph', child: Text(tr('Show row as graph'))),
        PopupMenuItem(value: 'copy', child: Text(tr('Copy table (Excel)'))),
        PopupMenuItem(value: 'export', child: Text(tr('Export to CSV file...'))),
      ],
    );
    if (a == null || !mounted) return;
    switch (a) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _table.toTsv()));
        if (mounted) showInfo(context, tr('Table copied to clipboard.'));
      case 'export':
        final f = await browse(
          context,
          st.backend,
          title: tr('Export results'),
          mode: BrowseMode.saveFile,
          extensions: const ['.csv'],
          initial: dirName(st.resultsSession),
          defaultName: '${_algorithm}_results.csv',
        );
        if (f == null) return;
        final sum = await st.backend.sessionSummary(st.resultsSession);
        final header =
            'session;${st.resultsSession}\nalgorithm;$_algorithm\n'
            '${sum.comment.isEmpty ? '' : 'comment;${sum.comment.replaceAll('\n', ' ')}\n'}\n';
        await st.backend.writeText(
          f,
          header + [_table.header.join(';'), for (final r in _table.rows) r.join(';')].join('\n'),
        );
        if (mounted) showInfo(context, '${tr('Exported to')} $f');
      case 'graph':
        await _showGraph(row);
    }
  }

  Future<void> _showGraph(int row) async {
    final st = AppScope.read(context);
    final name = row < _table.variableNames.length ? _table.variableNames[row] : '';
    if (name.isEmpty) return;
    try {
      final cfg = ResultViewConfig.fromJson(st.settings.resultView.toJson())..variables = [];
      final d = await st.backend.resultData(st.resultsSession, _algorithm, cfg);
      final chn = row < _table.channelIndex.length ? _table.channelIndex[row] : 1;
      final ch = d.channels[(chn - 1).clamp(0, d.channels.length - 1)];
      final q = ch.firstWhere((e) => e.name == name);
      List<double>? x;
      var xl = 'index';
      if (q.isGraph && q.graphX.isNotEmpty) {
        final xq = ch.where((e) => e.name == q.graphX);
        if (xq.isNotEmpty) {
          x = xq.first.value;
          xl = q.graphX;
        }
      }
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => Dialog(
          child: SizedBox(
            width: 900,
            height: 560,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('$name [${q.tag}] - ${q.desc}', style: Theme.of(context).textTheme.titleMedium),
                  Expanded(
                    child: q.value.length <= 1 && d.count > 1
                        ? Center(child: Text(tr('Scalar quantity: use "Scalar" view mode to see its history.')))
                        : LineChart(
                            xLabel: xl,
                            yLabel: name,
                            series: [
                              ChartSeries(
                                name,
                                q.value,
                                x: x != null && x.length == q.value.length ? x : null,
                                color: chartColors[0],
                                bars: q.value.length < 64,
                              ),
                              if (q.unc.length == q.value.length && q.unc.any((u) => u != 0)) ...[
                                ChartSeries(
                                  '+U',
                                  [for (var i = 0; i < q.value.length; i++) q.value[i] + q.unc[i]],
                                  x: x != null && x.length == q.value.length ? x : null,
                                  color: chartColors[1],
                                ),
                                ChartSeries(
                                  '-U',
                                  [for (var i = 0; i < q.value.length; i++) q.value[i] - q.unc[i]],
                                  x: x != null && x.length == q.value.length ? x : null,
                                  color: chartColors[1],
                                ),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final c = st.settings.resultView;
    final session = st.resultsSession;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Choice<_MeasSel>(
                label: tr('Measurement selection'),
                value: _sel,
                items: _MeasSel.values,
                width: 190,
                itemLabel: (v) => {
                  _MeasSel.none: tr('None'),
                  _MeasSel.current: tr('Current'),
                  _MeasSel.file: tr('Load from file'),
                }[v]!,
                onChanged: (v) async {
                  if (v == _MeasSel.file) {
                    final f = await browse(
                      context,
                      st.backend,
                      title: tr('Select measurement session'),
                      extensions: const ['session.info'],
                      initial: st.settings.measurement.folder,
                    );
                    if (f == null) return;
                    st.viewedSession = f;
                  } else {
                    st.viewedSession = '';
                  }
                  st.viewerEnabled = v != _MeasSel.none;
                  setState(() => _sel = v);
                  st.touch();
                  _schedule(reloadInfo: true, resetAlg: true);
                },
              ),
              SizedBox(
                width: 330,
                child: Text(
                  '${tr('Selected measurement')}:\n${session.isEmpty ? '-' : dirName(session)}',
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Choice<String>(
                label: tr('Algorithm selection'),
                value: _algorithm,
                items: _info.algorithms.isEmpty ? [''] : _info.algorithms,
                width: 200,
                itemLabel: (v) => v.isEmpty ? '-' : v,
                onChanged: (v) {
                  _algorithm = v;
                  _schedule(reloadInfo: true);
                },
              ),
              Choice<ResultDim>(
                label: tr('Max. shown dimension'),
                value: c.maxDim,
                items: ResultDim.values,
                width: 170,
                itemLabel: (v) => v.name[0].toUpperCase() + v.name.substring(1),
                onChanged: (v) => _cfg((c) => c.maxDim = v),
              ),
              Choice<int>(
                label: tr('Result selection'),
                value: c.resultId,
                items: [-1, 0, for (var i = 1; i <= _info.files.length; i++) i],
                width: 170,
                itemLabel: (v) => v == -1 ? tr('Current result') : (v == 0 ? tr('Average') : 'Result #$v'),
                enabled: c.maxDim != ResultDim.scalar,
                onChanged: (v) => _cfg((c) => c.resultId = v),
              ),
              Choice<UncDisplay>(
                label: tr('Uncertainty display'),
                value: c.unc,
                items: UncDisplay.values,
                width: 170,
                itemLabel: (v) => {
                  UncDisplay.none: tr('None'),
                  UncDisplay.plusMinus: tr('Value ± unc.'),
                  UncDisplay.alternateRows: tr('Alternate rows'),
                }[v]!,
                onChanged: (v) => _cfg((c) => c.unc = v),
              ),
              Choice<GroupMode>(
                label: tr('Res. order mode'),
                value: c.group,
                items: GroupMode.values,
                width: 170,
                itemLabel: (v) => v == GroupMode.byChannels ? tr('Group phases') : tr('Group quantities'),
                onChanged: (v) => _cfg((c) => c.group = v),
              ),
              Choice<PhaseMode>(
                label: tr('Phase mode'),
                value: c.phase,
                items: PhaseMode.values,
                width: 150,
                itemLabel: (v) => v.label,
                onChanged: (v) => _cfg((c) => c.phase = v),
              ),
              Choice<int>(
                label: tr('Ref. channel'),
                value: c.phaseRefChannel,
                items: [0, for (var i = 1; i <= _info.channels.length; i++) i],
                width: 150,
                itemLabel: (v) => v == 0 ? tr('- none -') : _info.channels[v - 1],
                onChanged: (v) => _cfg((c) => c.phaseRefChannel = v),
              ),
              Choice<AmplitudeMode>(
                label: tr('Convert amplitude'),
                value: c.amplitude,
                items: AmplitudeMode.values,
                width: 150,
                itemLabel: (v) => v.label,
                onChanged: (v) => _cfg((c) => c.amplitude = v),
              ),
              NumField(
                label: tr('Max. shown array size'),
                value: c.maxArray.toDouble(),
                integer: true,
                min: 1,
                width: 150,
                onChanged: (v) => _cfg((c) => c.maxArray = v.round()),
              ),
              IconButton(
                tooltip: tr('Refresh'),
                onPressed: () => _schedule(reloadInfo: true),
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_error.isNotEmpty) Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _tableView()),
                const SizedBox(width: 8),
                SizedBox(
                  width: 170,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(tr('Select quantities'), style: Theme.of(context).textTheme.labelLarge),
                      TextButton(onPressed: () => _cfg((c) => c.variables = []), child: Text(tr('--- Select all ---'))),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final v in _info.variables)
                              CheckboxListTile(
                                dense: true,
                                value: c.variables.isEmpty || c.variables.contains(v),
                                title: Text(v),
                                onChanged: (on) => _cfg((c) {
                                  if (c.variables.isEmpty) c.variables = [..._info.variables];
                                  on == true ? c.variables.add(v) : c.variables.remove(v);
                                  if (c.variables.length == _info.variables.length) c.variables = [];
                                }),
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
          Container(
            height: 40,
            padding: const EdgeInsets.all(6),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              _row >= 0 && _row < _table.descriptions.length
                  ? '${tr('Info')}: ${_table.descriptions[_row]}'
                  : '${tr('Info')}:',
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableView() {
    final t = _table;
    if (t.rows.isEmpty) {
      return Center(
        child: Text(
          AppScope.of(context).resultsSession.isEmpty
              ? tr('No measurement selected.')
              : (_info.exists
                    ? (_busy ? tr('Loading...') : tr('No results.'))
                    : tr('No results available for this measurement.')),
        ),
      );
    }
    final theme = Theme.of(context);
    final ncol = t.header.length;
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: theme.dividerColor),
            children: [
              TableRow(
                decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh),
                children: [
                  for (var c = 0; c < ncol; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text(t.header[c], style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
              for (var r = 0; r < t.rows.length; r++)
                TableRow(
                  decoration: BoxDecoration(color: r == _row ? theme.colorScheme.primaryContainer : null),
                  children: [
                    for (var c = 0; c < ncol; c++)
                      GestureDetector(
                        onTap: () => setState(() => _row = r),
                        onDoubleTap: () => _showGraph(r),
                        onSecondaryTapDown: (d) {
                          setState(() => _row = r);
                          _rowMenu(d.globalPosition, r);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          child: Text(
                            c < t.rows[r].length ? t.rows[r][c] : '',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              fontWeight: c == 0 ? FontWeight.bold : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
