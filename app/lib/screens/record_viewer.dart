import 'dart:async';

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
  WaveformData? _zoom; // zoomed part at full resolution
  Timer? _zoomTimer;
  SpectrumData? _spec; // of the whole record, for the spectrum view
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

  /// Zoomed in a decimated record: load the visible part at full resolution
  /// (like the deep memory of a scope), back to the whole record on reset.
  void _onView(Rect? v) {
    _zoomTimer?.cancel();
    final d = _data;
    if (v == null || d == null) {
      if (_zoom != null) setState(() => _zoom = null);
      return;
    }
    _zoomTimer = Timer(const Duration(milliseconds: 200), () async {
      final ts = d.fullTs > 0 ? d.fullTs : d.ts;
      final from = (v.left / ts).floor().clamp(0, d.fullLength);
      final to = (v.right / ts).ceil().clamp(0, d.fullLength);
      if (to - from >= d.fullLength * 0.9 || to <= from) {
        if (_zoom != null && mounted) setState(() => _zoom = null);
        return;
      }
      try {
        final z = await AppScope.read(context).backend.readRecord(
          _session,
          _group,
          _record,
          maxPoints: _maxPoints,
          from: from,
          count: to - from,
        );
        if (mounted) setState(() => _zoom = z);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _zoomTimer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final s = _sum;
    if (s == null || s.recordsPerGroup.isEmpty || s.recordsPerGroup[_group - 1] == 0) return;
    setState(() => _busy = true);
    try {
      final b = AppScope.read(context).backend;
      final d = await b.readRecord(_session, _group, _record, maxPoints: _maxPoints);
      _zoom = null;
      // spectrum from all samples: the decimated waveform would alias fast content
      final sp = _spectrum ? await b.recordSpectrum(_session, _group, _record) : null;
      setState(() {
        _data = d;
        _spec = sp;
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
          final sp = _spec;
          if (sp == null || c >= sp.amplitudes.length) continue;
          series.add(ChartSeries(name, sp.amplitudes[c], dx: sp.df, color: chartColors[c % chartColors.length]));
        } else {
          final w = _zoom ?? d;
          if (c >= w.channels.length) continue;
          series.add(ChartSeries(name, w.channels[c], x0: w.x0, dx: w.ts, color: chartColors[c % chartColors.length]));
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
              Check(
                label: tr('Spectrum'),
                value: _spectrum,
                onChanged: (v) {
                  setState(() => _spectrum = v);
                  if (v && _spec == null) _read();
                },
              ),
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
                    onViewChanged: _spectrum ? null : _onView,
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
