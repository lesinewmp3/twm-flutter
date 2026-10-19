import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/chart.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/paths.dart';

/// Record viewer (TWM guide figure 3.32): rereads the stored record files.
Future<void> showRecordViewer(BuildContext context) => showDialog(
  context: context,
  builder: (_) => AppScope(state: AppScope.read(context), child: const _RecordViewer()),
);

class _RecordViewer extends StatefulWidget {
  const _RecordViewer();
  @override
  State<_RecordViewer> createState() => _RecordViewerState();
}

class _RecordViewerState extends State<_RecordViewer> {
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
    if (_session.isNotEmpty) _open(_session, last: true);
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
            '${d.fullLength} samples per channel'
            '${d.channels.isNotEmpty && d.channels.first.length < d.fullLength ? ' (decimated to ${d.channels.first.length} points)' : ''}';
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
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1150,
        height: 720,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Record viewer', style: Theme.of(context).textTheme.titleLarge),
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
                        title: 'Select measurement session',
                        extensions: const ['session.info'],
                        initial: _session.isEmpty ? st.settings.measurement.folder : dirName(_session),
                      );
                      if (f != null) await _open(f);
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Session...'),
                  ),
                  SizedBox(width: 360, child: Text(_session.isEmpty ? '(no session)' : dirName(_session), maxLines: 2)),
                  if (s != null && s.recordsPerGroup.length > 1)
                    Choice<int>(
                      label: 'Group',
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
                      label: 'Record',
                      value: _record.clamp(1, recs),
                      items: [for (var r = 1; r <= recs; r++) r],
                      width: 110,
                      onChanged: (v) {
                        setState(() => _record = v);
                        _read();
                      },
                    ),
                  NumField(
                    label: 'Max samples to display',
                    value: _maxPoints.toDouble(),
                    integer: true,
                    min: 100,
                    width: 180,
                    onChanged: (v) {
                      _maxPoints = v.round();
                      _read();
                    },
                  ),
                  Check(label: 'Spectrum', value: _spectrum, onChanged: (v) => setState(() => _spectrum = v)),
                  if (_busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              if (s != null && s.comment.isNotEmpty)
                Text('Comment: ${s.comment}', style: Theme.of(context).textTheme.bodySmall),
              Text(_msg, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Expanded(
                child: series.isEmpty
                    ? const Center(child: Text('No data.'))
                    : LineChart(
                        series: series,
                        xLabel: _spectrum ? 'frequency [Hz]' : 'time [s]',
                        yLabel: _spectrum ? 'amplitude [V]' : 'voltage [V]',
                        logY: _spectrum,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
