import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/paths.dart';
import 'processing_dialog.dart';

/// QWTB batch processing panel (TWM guide figure 3.36, TPQA "TWM
/// processing panel"): processing of previously recorded measurements.
Future<void> showBatchDialog(BuildContext context) => showDialog(
  context: context,
  barrierDismissible: false,
  builder: (_) => AppScope(state: AppScope.read(context), child: const _BatchDialog()),
);

class _BatchDialog extends StatefulWidget {
  const _BatchDialog();
  @override
  State<_BatchDialog> createState() => _BatchDialogState();
}

class _BatchDialogState extends State<_BatchDialog> {
  String _session = '';
  SessionSummary? _sum;
  int _group = 1;
  final Set<int> _sel = {};
  late ProcessingSetup _setup = AppScope.read(context).settings.measurement.processing.copy();
  bool _running = false;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    final s = AppScope.read(context).resultsSession;
    if (s.isNotEmpty) _open(s);
  }

  Future<void> _open(String path) async {
    try {
      final s = await AppScope.read(context).backend.sessionSummary(path);
      setState(() {
        _session = path;
        _sum = s;
        _group = s.recordsPerGroup.isEmpty ? 1 : s.recordsPerGroup.length;
        _sel
          ..clear()
          ..addAll([for (var r = 1; r <= (s.recordsPerGroup.isEmpty ? 0 : s.recordsPerGroup[_group - 1]); r++) r]);
        _msg =
            '${s.channels.length} channels, ${s.recordsPerGroup.join('/')} records, '
            'transducers: ${s.transducerTags.isEmpty ? '(none)' : s.transducerTags.join(', ')}';
      });
    } catch (e) {
      setState(() => _msg = '$e');
    }
  }

  Future<void> _start() async {
    final st = AppScope.read(context);
    if (_sel.isEmpty) return;
    setState(() => _running = true);
    try {
      await st.backend.octaveStart(st.settings.octave);
      await st.backend.processRecords(_session, _setup, group: _group, records: _sel.toList()..sort());
      st.viewedSession = _session;
      st.resultsVersion++;
      st.touch();
      setState(() => _msg = 'Done. Results shown in the main window results viewer.');
    } catch (e) {
      setState(() => _msg = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final s = _sum;
    final recs = s == null || s.recordsPerGroup.isEmpty ? 0 : s.recordsPerGroup[_group - 1];
    return AlertDialog(
      title: const Text('QWTB batch processing'),
      content: SizedBox(
        width: 800,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Measurement session: ${_session.isEmpty ? '(select)' : dirName(_session)}')),
                OutlinedButton.icon(
                  onPressed: _running
                      ? null
                      : () async {
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
                  label: const Text('Select...'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(_msg, style: Theme.of(context).textTheme.bodySmall),
            if (s != null && s.recordsPerGroup.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Choice<int>(
                  label: 'Measurement group',
                  value: _group,
                  width: 180,
                  items: [for (var g = 1; g <= s.recordsPerGroup.length; g++) g],
                  onChanged: (v) => setState(() {
                    _group = v;
                    _sel.clear();
                  }),
                ),
              ),
            Row(
              children: [
                Text('Records', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _sel.addAll([for (var r = 1; r <= recs; r++) r])),
                  child: const Text('All'),
                ),
                TextButton(onPressed: () => setState(_sel.clear), child: const Text('None')),
              ],
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor)),
                child: GridView.count(
                  crossAxisCount: 8,
                  childAspectRatio: 2.6,
                  children: [
                    for (var r = 1; r <= recs; r++)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('A$r'),
                        value: _sel.contains(r),
                        onChanged: _running ? null : (v) => setState(() => v == true ? _sel.add(r) : _sel.remove(r)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _running
                      ? null
                      : () async {
                          final r = await showProcessingDialog(context, _setup);
                          if (r != null) setState(() => _setup = r);
                        },
                  icon: const Icon(Icons.calculate),
                  label: const Text('PROCESSING SETUP'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _setup.mode == ProcessingMode.raw
                        ? 'RAW m-code'
                        : '${_setup.algorithmId}, uncertainty ${_setup.uncertainty.key}',
                  ),
                ),
              ],
            ),
            if (_running) ...[const SizedBox(height: 8), Text(st.status), LinearProgressIndicator(value: st.progress)],
            const SizedBox(height: 4),
            const Text(
              'Processing the same algorithm again overwrites its previous results; results of other '
              'algorithms are kept.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('Close')),
        OutlinedButton(onPressed: _running ? () => st.backend.stopProcessing() : null, child: const Text('STOP')),
        FilledButton(
          onPressed: _running || _session.isEmpty || _sel.isEmpty ? null : _start,
          child: const Text('START'),
        ),
      ],
    );
  }
}
