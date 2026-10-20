import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../l10n.dart';
import '../state/app_state.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/paths.dart';

/// Record viewer (TWM guide figure 3.32): rereads the stored record files.
Future<void> showRecordViewer(BuildContext context) => showDialog(
  context: context,
  builder: (_) => AppScope(
    state: AppScope.read(context),
    child: const Dialog(
      insetPadding: EdgeInsets.all(24),
      child: SizedBox(width: 1150, height: 720, child: RecordViewerPanel(dialog: true)),
    ),
  ),
);

/// Record viewer page / dialog content.
class RecordViewerPanel extends StatefulWidget {
  final bool dialog;
  const RecordViewerPanel({super.key, this.dialog = false});
  @override
  State<RecordViewerPanel> createState() => _RecordViewerState();
}

class _RecordViewerState extends State<RecordViewerPanel> {
  String _lastCurrent = '';
  String _session = '';
  SessionSummary? _sum;
  int _group = 1;
  int _record = 1;
  int _maxPoints = 20000;
  WaveformData? _data;
  String _msg = '';
  bool _busy = false;
  bool _spectrum = false;

  @override
  void initState() {
    super.initState();
    _session = AppScope.read(context).resultsSession;
    _lastCurrent = _session;
    if (_session.isNotEmpty) _open(_session, last: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // follow the current measurement when a new record arrives
    final cur = AppScope.of(context).currentSession;
    if (cur.isNotEmpty && cur != _lastCurrent && !widget.dialog) {
      _lastCurrent = cur;
      _open(cur, last: true);
    }
  }

  Future<void> _open(String s, {bool last = false}) async {
    final st = AppScope.read(context);
    try {
      final sum = await st.backend.sessionSummary(s);
      setState(() {
        _session = s;
        _sum = sum;
        _group = sum.recordsPerGroup.isEmpty ? 1 : sum.recordsPerGroup.length;
        _record = last && sum.recordsPerGroup.isNotEmpty ? sum.recordsPerGroup.last : 1;
      });
      await _read();
    } catch (e) {
      setState(() => _msg = '$e');
    }
  }

  Future<void> _read() async {
    final s = _sum;
    if (s == null || s.recordsPerGroup.isEmpty || s.recordsPerGroup[_group - 1] == 0) return;
    setState(() => _busy = true);
    try {
      final d = await AppScope.read(context).backend.readRecord(_session, _group, _record, maxPoints: _maxPoints);
      setState(() {
        _data = d;
        _msg =
            '${d.fullLength} ${tr('samples per channel')}'
            '${d.channels.isNotEmpty && d.channels.first.length < d.fullLength ? ' (${tr('decimated to')} ${d.channels.first.length})' : ''}';
      });
    } catch (e) {
      setState(() => _msg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final s = _sum;
    final d = _data;
    final recs = s == null || s.recordsPerGroup.isEmpty ? 0 : s.recordsPerGroup[_group - 1];
    List<ChartSeries> series = [];
    if (d != null) {
      for (var c = 0; c < d.channels.length; c++) {
        final name = '#${c + 1} ${c < d.names.length ? d.names[c] : ''}';
        if (_spectrum) {
          // note: decimated records give spectrum up to the reduced Nyquist frequency
          final sp = Spectrum.of(Float64List.fromList(d.channels[c]), 1 / d.ts, window: WindowType.hann);
          final y = sp.forDisplay(8192);
          series.add(
            ChartSeries(
              name,
              y,
              dx: sp.df * (sp.amp.length / y.length).ceilToDouble(),
              color: chartColors[c % chartColors.length],
            ),
          );
        } else {
          series.add(ChartSeries(name, d.channels[c], dx: d.ts, color: chartColors[c % chartColors.length]));
        }
      }
    }
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.dialog)
            Row(
              children: [
                Text(tr('Record viewer'), style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final f = await browse(
                    context,
                    st.backend,
                    title: tr('Select measurement session'),
                    extensions: const ['session.info'],
                    initial: _session.isEmpty ? st.settings.measurement.folder : dirName(_session),
                  );
                  if (f != null) await _open(f);
                },
                icon: const Icon(Icons.folder_open),
                label: Text(tr('Session...')),
              ),
              SizedBox(width: 360, child: Text(_session.isEmpty ? tr('(no session)') : dirName(_session), maxLines: 2)),
              if (s != null && s.recordsPerGroup.length > 1)
                Choice<int>(
                  label: tr('Group'),
                  value: _group,
                  items: [for (var g = 1; g <= s.recordsPerGroup.length; g++) g],
                  width: 100,
                  onChanged: (v) {
                    setState(() => _group = v);
                    _read();
                  },
                ),
              if (recs > 0)
                Choice<int>(
                  label: tr('Record'),
                  value: _record.clamp(1, recs),
                  items: [for (var r = 1; r <= recs; r++) r],
                  width: 110,
                  onChanged: (v) {
                    setState(() => _record = v);
                    _read();
                  },
                ),
              NumField(
                label: tr('Max samples to display'),
                value: _maxPoints.toDouble(),
                integer: true,
                min: 100,
                width: 180,
                onChanged: (v) {
                  _maxPoints = v.round();
                  _read();
                },
              ),
              Check(label: tr('Spectrum'), value: _spectrum, onChanged: (v) => setState(() => _spectrum = v)),
              if (_busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (s != null && s.comment.isNotEmpty)
            Text('${tr('Comment')}: ${s.comment}', style: Theme.of(context).textTheme.bodySmall),
          Text(_msg, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Expanded(
            child: series.isEmpty
                ? Center(child: Text(tr('No data - select a measurement session.')))
                : LineChart(
                    series: series,
                    xLabel: _spectrum ? tr('frequency [Hz]') : tr('time [s]'),
                    yLabel: _spectrum ? tr('amplitude [V]') : tr('voltage [V]'),
                    logY: _spectrum,
                  ),
          ),
        ],
      ),
    );
    return widget.dialog
        ? content
        : Padding(
            padding: const EdgeInsets.all(16),
            child: Card(child: content),
          );
  }
}
