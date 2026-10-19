import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/paths.dart';
import '../widgets/rows_editor.dart';
import 'correction_editor.dart';

/// HW corrections panel (TWM guide 3.1.4.3, TPQA guide 3.3.3.2): list of
/// transducers with mapping to digitizer channels, and the digitizer
/// correction file.
Future<void> showCorrectionsDialog(BuildContext context) => showDialog(
  context: context,
  barrierDismissible: false,
  builder: (_) => AppScope(state: AppScope.read(context), child: const _CorrectionsDialog()),
);

class _CorrectionsDialog extends StatefulWidget {
  const _CorrectionsDialog();
  @override
  State<_CorrectionsDialog> createState() => _CorrectionsDialogState();
}

class _CorrectionsDialogState extends State<_CorrectionsDialog> {
  late CorrectionsConfig c = CorrectionsConfig.fromJson(AppScope.read(context).settings.corrections.toJson());
  CorrectionSummary? _dig;
  String _digMsg = '';
  bool _digErr = false;

  @override
  void initState() {
    super.initState();
    _loadDigitizer();
  }

  String _abs(String path) =>
      isAbsolutePath(path) || c.transducersRoot.isEmpty ? path : joinPath(c.transducersRoot, path);

  Future<void> _loadDigitizer() async {
    if (c.digitizerPath.isEmpty) {
      setState(() => _dig = null);
      return;
    }
    final s = await AppScope.read(context).backend.correctionSummary(c.digitizerPath);
    if (!mounted) return;
    setState(() {
      _dig = s;
      c.digitizerName = s.name;
      _digErr = s.error.isNotEmpty || s.type != 'digitizer';
      _digMsg = s.error.isNotEmpty
          ? s.error
          : (s.type != 'digitizer' ? 'File is not a digitizer correction (type: ${s.type})!' : 'Loaded: ${s.name}');
    });
  }

  Future<void> _loadTransducer(TransducerConfig t, String path) async {
    final st = AppScope.read(context);
    final s = await st.backend.correctionSummary(_abs(path));
    if (!mounted) return;
    setState(() {
      t.path = c.transducersRoot.isNotEmpty ? relativeTo(path, c.transducersRoot) : path;
      if (t.path.startsWith('..')) t.path = path;
      t.name = s.error.isNotEmpty ? 'ERROR: ${s.error}' : s.name;
      t.serial = s.serial;
      t.type = s.type == 'shunt' ? TransducerType.shunt : TransducerType.divider;
      t.nominalRatio = s.nominalRatio;
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final dig = st.settings.digitizer;
    final n = dig.physicalChannelsCount;
    final mux = dig.multiplexer;
    final errs = c.validate(n, muxPaths: mux.enabled ? mux.sequence : const []);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1150,
        height: 760,
        child: DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DialogHeader(
                'HW corrections',
                bottom: const TabBar(
                  tabs: [
                    Tab(text: 'Transducers'),
                    Tab(text: 'Digitizer'),
                  ],
                ),
              ),
              Expanded(child: TabBarView(children: [_transducersTab(st, n, mux, errs), _digitizerTab(st)])),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        st.update((s) => s.corrections = c);
                        Navigator.pop(context);
                      },
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _transducersTab(AppState st, int n, MultiplexerConfig mux, List<String> errs) {
    final b = st.backend;
    final chItems = [for (var i = 1; i <= n; i++) i];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PathField(
            label: 'Transducer corrections root path',
            value: c.transducersRoot,
            backend: b,
            mode: BrowseMode.folder,
            onChanged: (v) => setState(() => c.transducersRoot = v),
          ),
          const SizedBox(height: 8),
          RowsEditor<TransducerConfig>(
            title: 'List of the transducers',
            rows: c.transducers,
            minRows: 0,
            create: () => TransducerConfig(
              highChannel: (c.transducers.length % (n == 0 ? 1 : n)) + 1,
              phaseIndex: c.transducers.length ~/ 2 + 1,
              multiplexerPath: mux.enabled ? mux.sequence.first : '',
            ),
            onChanged: () => setState(() {}),
            rowBuilder: (ctx, i, t) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: PathField(
                        label: 'Correction file',
                        value: t.path,
                        backend: b,
                        extensions: const ['.info'],
                        onChanged: (v) => _loadTransducer(t, v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: t.path.isEmpty
                          ? null
                          : () async {
                              final saved = await showTransducerEditor(context, _abs(t.path));
                              if (saved != null) await _loadTransducer(t, saved);
                            },
                      child: const Text('Edit'),
                    ),
                  ],
                ),
                FieldRow([
                  SizedBox(
                    width: 280,
                    child: Text(
                      t.path.isEmpty
                          ? '(no file)'
                          : '${t.type == TransducerType.shunt ? 'SHUNT' : 'DIVIDER'}  ratio ${formatNum(t.nominalRatio)}'
                                '${t.type == TransducerType.shunt ? ' V/A' : ''}\n${t.name}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  NumField(
                    label: 'Phase index',
                    value: t.phaseIndex.toDouble(),
                    integer: true,
                    min: 1,
                    width: 100,
                    onChanged: (v) => setState(() => t.phaseIndex = v.round()),
                  ),
                  Choice<int>(
                    label: 'High',
                    value: t.highChannel,
                    items: chItems,
                    width: 100,
                    itemLabel: (k) => '#$k',
                    onChanged: (v) => setState(() => t.highChannel = v),
                  ),
                  Choice<int>(
                    label: 'Low',
                    value: t.lowChannel,
                    items: [0, ...chItems],
                    width: 120,
                    itemLabel: (k) => k == 0 ? 'Not used' : '#$k',
                    onChanged: (v) => setState(() => t.lowChannel = v),
                  ),
                  if (mux.enabled)
                    Choice<String>(
                      label: 'Multiplexer',
                      value: t.multiplexerPath,
                      items: mux.sequence.toSet().toList(),
                      width: 120,
                      onChanged: (v) => setState(() => t.multiplexerPath = v),
                    ),
                  Check(label: 'Inverted', value: t.inverted, onChanged: (v) => setState(() => t.inverted = v)),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 8),
          MessageBox(errs.isEmpty ? 'OK' : errs.join('\n'), error: errs.isNotEmpty, height: 80),
          const SizedBox(height: 8),
          const Text(
            'Single input algorithms: each transducer is processed as a standalone channel; without transducers all '
            'channels are processed as voltages with unity correction. Paired algorithms (power) require one shunt and '
            'one divider with the same phase index. Use the dummy corrections from data/corrections/transducers if no '
            'correction is needed.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _digitizerTab(AppState st) {
    final d = _dig;
    final hw = st.channelIdns;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Digitizer correction file: ${c.digitizerPath.isEmpty ? '(none)' : c.digitizerPath}'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () async {
                  final f = await browse(
                    context,
                    st.backend,
                    title: 'Load digitizer corrections',
                    initial: c.digitizerPath,
                    extensions: const ['.info'],
                  );
                  if (f == null) return;
                  c.digitizerPath = f;
                  await _loadDigitizer();
                },
                child: const Text('LOAD NEW CORRECTIONS'),
              ),
              OutlinedButton(onPressed: _loadDigitizer, child: const Text('RELOAD CORRECTIONS')),
              OutlinedButton(
                onPressed: () => setState(() {
                  c.digitizerPath = '';
                  c.digitizerName = '';
                  _dig = null;
                  _digMsg = 'Digitizer corrections cleared.';
                  _digErr = false;
                }),
                child: const Text('CLEAR CORRECTIONS'),
              ),
              OutlinedButton(
                onPressed: () async {
                  var ids = hw;
                  if (ids.isEmpty) {
                    final r = await st.backend.testDigitizer(st.settings.digitizer);
                    ids = r.channelIdns;
                    st.channelIdns = ids;
                  }
                  final corr = _dig?.channelIdentifiers ?? const [];
                  final ok =
                      corr.length == ids.length && List.generate(ids.length, (i) => ids[i] == corr[i]).every((e) => e);
                  setState(() {
                    _digErr = !ok;
                    _digMsg = ok
                        ? 'HW consistency OK.'
                        : 'Digitizer channels do not match the correction file!\n'
                              'HW:         ${ids.join(' | ')}\nCorrection: ${corr.join(' | ')}';
                  });
                },
                child: const Text('CHECK HW CONSISTENCY'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final saved = await showDigitizerCorrectionEditor(context, c.digitizerPath);
                  if (saved != null) {
                    c.digitizerPath = saved;
                    await _loadDigitizer();
                  }
                },
                child: const Text('EDIT CORRECTION'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (d != null) ...[
            Text('Name: ${d.name}'),
            const SizedBox(height: 4),
            const Text('Channel identifiers:'),
            for (final id in d.channelIdentifiers) Text('   $id', style: const TextStyle(fontFamily: 'monospace')),
          ],
          const SizedBox(height: 8),
          MessageBox(_digMsg, error: _digErr, height: 100),
          const SizedBox(height: 8),
          const Text(
            'TWM works without digitizer corrections, only corrections enabled by default (aperture correction) are '
            'applied. Channel names and order in the correction file must match the configured digitizer.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
