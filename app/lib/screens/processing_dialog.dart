import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../l10n.dart';

/// Processing configuration panel (TWM guide figures 3.27 - 3.29, TPQA
/// "QWTB processing algorithms"). Returns modified copy or null.
Future<ProcessingSetup?> showProcessingDialog(BuildContext context, ProcessingSetup setup) =>
    showScopedDialog<ProcessingSetup>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProcDialog(setup.copy()),
    );

class _ProcDialog extends StatefulWidget {
  final ProcessingSetup ps;
  const _ProcDialog(this.ps);
  @override
  State<_ProcDialog> createState() => _ProcDialogState();
}

class _ProcDialogState extends State<_ProcDialog> {
  late final ProcessingSetup ps = widget.ps;
  List<AlgorithmSummary> _algs = [];
  AlgorithmInfo? _info;
  bool _loading = false;
  String _error = '';
  int _selParam = -1;
  int _rev = 0;

  @override
  void initState() {
    super.initState();
    _loadAlgs();
  }

  Future<void> _loadAlgs() async {
    final st = AppScope.read(context);
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await st.backend.octaveStart(st.settings.octave);
      final a = await st.backend.algorithms();
      setState(() => _algs = a);
      if (ps.algorithmId.isNotEmpty && a.any((e) => e.id == ps.algorithmId)) {
        await _loadAlg(ps.algorithmId, keepParams: true);
      }
    } catch (e) {
      setState(() => _error = 'Cannot load algorithms: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadAlg(String id, {bool keepParams = false}) async {
    setState(() => _loading = true);
    try {
      final i = await AppScope.read(context).backend.algorithmInfo(id);
      setState(() {
        _info = i;
        ps.algorithmId = id;
        final old = {for (final p in ps.parameters) p.name: p.values};
        ps.parameters = [
          for (final p in i.parameters) AlgorithmParameter(p.name, keepParams ? (old[p.name] ?? []) : []),
        ];
        if (ps.uncertainty == UncertaintyMode.guf && !i.uncGuf) ps.uncertainty = UncertaintyMode.none;
        if (ps.uncertainty == UncertaintyMode.mcm && !i.uncMcm) ps.uncertainty = UncertaintyMode.none;
        if (!i.supportMultiRecords) ps.wholeAverageAtOnce = false;
        _selParam = -1;
        _rev++;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _octave => AppScope.read(context).backend.features.octave;

  @override
  Widget build(BuildContext context) {
    if (!_octave) ps.mode = ProcessingMode.qwtb;
    return Dialog(
      insetPadding: EdgeInsets.all(24),
      child: SizedBox(
        width: 1150,
        height: 800,
        child: DefaultTabController(
          length: _octave ? 2 : 1,
          initialIndex: _octave && ps.mode == ProcessingMode.raw ? 0 : (_octave ? 1 : 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DialogHeader(
                tr('Processing setup'),
                bottom: TabBar(
                  onTap: (i) => ps.mode = _octave && i == 0 ? ProcessingMode.raw : ProcessingMode.qwtb,
                  tabs: [
                    if (_octave) Tab(text: tr('RAW command')),
                    Tab(text: tr('QWTB')),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [if (_octave) _raw(), _qwtb()],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    if (_loading)
                      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                    TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: () => Navigator.pop(context, ps), child: Text(tr('OK'))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _raw() => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr(
            'm-code executed on each record. Loaded data are in structure "data" '
            '(data.y - samples, one column per channel, data.Ts - sampling period, data.corr - corrections). '
            'Printed output appears in the RAW tab of the main window.',
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextEntry(label: tr('m-code'), value: ps.rawCode, maxLines: 30, onChanged: (v) => ps.rawCode = v),
        ),
        Row(
          children: [
            OutlinedButton(
              onPressed: () async {
                final b = AppScope.read(context).backend;
                final f = await browse(context, b, title: tr('Load m-file'), extensions: const ['.m']);
                if (f == null) return;
                final t = await b.readText(f);
                setState(() {
                  ps.rawCode = t;
                  _rev++;
                });
              },
              child: Text(tr('Load from file')),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _led(String label, bool on) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 14, color: on ? Colors.green : Colors.grey.shade400),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
      const SizedBox(width: 12),
    ],
  );

  Widget _qwtb() {
    final i = _info;
    final params = i?.parameters ?? const <AlgorithmInput>[];
    final st = AppScope.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Text(tr('List of algorithms'), style: Theme.of(context).textTheme.titleSmall),
                    const Spacer(),
                    TextButton(onPressed: _loading ? null : _loadAlgs, child: Text(tr('RELOAD ALGs'))),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final a in _algs)
                      ListTile(
                        dense: true,
                        selected: a.id == ps.algorithmId,
                        title: Text(a.id),
                        subtitle: Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: _loading ? null : () => _loadAlg(a.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              key: ValueKey(_rev),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (i != null) ...[
                  Text('${i.id} - ${i.name}', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  SelectableText(i.desc),
                  if (i.citation.isNotEmpty)
                    SelectableText('${tr('Citation')}: ${i.citation}', style: const TextStyle(fontSize: 12)),
                  if (i.remarks.isNotEmpty)
                    SelectableText('${tr('Remarks')}: ${i.remarks}', style: const TextStyle(fontSize: 12)),
                  if (i.license.isNotEmpty)
                    Text('${tr('License')}: ${i.license}', style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(
                    children: [
                      _led('multiple records', i.supportMultiRecords),
                      _led('differential inputs', i.supportDiff),
                      _led('u/i pair (power)', i.hasUi),
                      _led('GUF', i.uncGuf),
                      _led('Monte Carlo', i.uncMcm),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${tr('Outputs')}: ${i.outputs.map((o) => o.name).join(', ')}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Group(
                    title: tr('Parameters of the algorithm'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (params.isEmpty) Text(tr('(no user parameters)')),
                        for (var k = 0; k < params.length; k++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 240,
                                  child: InkWell(
                                    onTap: () => setState(() => _selParam = k),
                                    child: Text(
                                      params[k].label,
                                      style: TextStyle(fontWeight: _selParam == k ? FontWeight.bold : null),
                                    ),
                                  ),
                                ),
                                Expanded(child: _paramValue(params[k], k)),
                              ],
                            ),
                          ),
                        if (_selParam >= 0 && _selParam < params.length)
                          Container(
                            margin: const EdgeInsets.only(top: 6),
                            padding: const EdgeInsets.all(8),
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: Text('${tr('Variable description')}: ${params[_selParam].desc}'),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => setState(() {
                              for (final p in ps.parameters) {
                                p.values = [];
                              }
                              _rev++;
                            }),
                            child: Text(tr('CLEAR PARAMETERS')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
                  Text(tr('Select an algorithm.')),
                Group(
                  title: tr('Processing options'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FieldRow([
                        NumField(
                          label: tr('Start offset'),
                          unit: 'smpl',
                          value: ps.sampleOffset.toDouble(),
                          integer: true,
                          min: 0,
                          width: 150,
                          onChanged: (v) => ps.sampleOffset = v.round(),
                        ),
                        NumField(
                          label: tr('Input data length (0=all)'),
                          unit: 'smpl',
                          value: ps.sampleLimit.toDouble(),
                          integer: true,
                          min: 0,
                          width: 200,
                          onChanged: (v) => ps.sampleLimit = v.round(),
                        ),
                        Choice<TimeStampMode>(
                          label: tr('Time-stamp handling'),
                          value: ps.timeStampMode,
                          items: TimeStampMode.values,
                          width: 200,
                          itemLabel: (m) => {
                            TimeStampMode.enable: tr('Enable'),
                            TimeStampMode.disable: tr('Disable'),
                            TimeStampMode.relative: tr('Relative to 1. record'),
                          }[m]!,
                          onChanged: (v) => setState(() => ps.timeStampMode = v),
                        ),
                      ]),
                      Check(
                        label: tr('Calculate result just once for all records (multi-record algorithms)'),
                        value: ps.wholeAverageAtOnce,
                        enabled: i?.supportMultiRecords ?? false,
                        onChanged: (v) => setState(() => ps.wholeAverageAtOnce = v),
                      ),
                      if (_octave)
                        Check(
                          label: tr('Calculate uncertainty just once (first record)'),
                          value: ps.uncertaintyOnce,
                          onChanged: (v) => setState(() => ps.uncertaintyOnce = v),
                        ),
                      FieldRow([
                        Choice<UncertaintyMode>(
                          label: tr('Uncertainty calculation mode'),
                          value: ps.uncertainty,
                          width: 220,
                          items: [
                            UncertaintyMode.none,
                            if (i?.uncGuf ?? true) UncertaintyMode.guf,
                            if (i?.uncMcm ?? true) UncertaintyMode.mcm,
                          ],
                          itemLabel: (u) => {
                            UncertaintyMode.none: tr('None'),
                            UncertaintyMode.guf: tr('GUF (estimator)'),
                            UncertaintyMode.mcm: tr('Monte Carlo'),
                          }[u]!,
                          onChanged: (v) => setState(() => ps.uncertainty = v),
                        ),
                        NumField(
                          label: tr('Level of confidence'),
                          value: ps.levelOfConfidence,
                          min: 0.5,
                          max: 0.9999,
                          width: 150,
                          onChanged: (v) => ps.levelOfConfidence = v,
                        ),
                        if (ps.uncertainty == UncertaintyMode.mcm)
                          NumField(
                            label: tr('Monte Carlo cycles'),
                            value: ps.monteCarloCycles.toDouble(),
                            integer: true,
                            min: 10,
                            width: 160,
                            onChanged: (v) => ps.monteCarloCycles = v.round(),
                          ),
                        NumField(
                          label: tr('Processing timeout'),
                          unit: 's',
                          value: ps.timeout,
                          min: 1,
                          width: 150,
                          onChanged: (v) => ps.timeout = v,
                        ),
                      ]),
                    ],
                  ),
                ),
                if (_octave)
                  Group(
                    title: tr('Multicore processing'),
                    child: FieldRow([
                      Choice<ExecutionMode>(
                        label: tr('QWTB algorithms execution mode'),
                        value: ps.execution,
                        items: ExecutionMode.values,
                        width: 260,
                        itemLabel: (m) =>
                            m == ExecutionMode.singleCore ? tr('Single-core') : tr('Parallel record processing (exp.)'),
                        onChanged: (v) => setState(() => ps.execution = v),
                      ),
                      Choice<ParallelMode>(
                        label: tr('Parallel mode (Monte Carlo)'),
                        value: ps.parallel,
                        items: ParallelMode.values,
                        width: 220,
                        itemLabel: (m) => {
                          ParallelMode.singlecore: tr('Singlecore'),
                          ParallelMode.multicore: tr('Multicore (parcellfun/parfor)'),
                          ParallelMode.multistation: tr('Multistation (multicore pkg)'),
                        }[m]!,
                        onChanged: (v) => setState(() => ps.parallel = v),
                      ),
                      if (ps.parallel != ParallelMode.singlecore)
                        NumField(
                          label: tr('CPU cores'),
                          value: ps.cores.toDouble(),
                          integer: true,
                          min: 1,
                          width: 110,
                          onChanged: (v) => ps.cores = v.round(),
                        ),
                      if (ps.parallel == ParallelMode.multistation)
                        SizedBox(
                          width: 420,
                          child: PathField(
                            label: tr('Multistation jobs folder'),
                            value: ps.jobsFolder,
                            backend: st.backend,
                            mode: BrowseMode.folder,
                            onChanged: (v) => setState(() => ps.jobsFolder = v),
                          ),
                        ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _paramValue(AlgorithmInput inp, int k) {
    final p = ps.parameters.firstWhere(
      (e) => e.name == inp.name,
      orElse: () {
        final n = AlgorithmParameter(inp.name);
        ps.parameters.add(n);
        return n;
      },
    );
    if (inp.enumValues.isNotEmpty) {
      final cur = p.values.isEmpty ? '' : p.values.first;
      return Choice<String>(
        label: '',
        value: cur,
        items: ['', ...inp.enumValues],
        width: 260,
        itemLabel: (v) => v.isEmpty ? tr('(default)') : v,
        onChanged: (v) => setState(() => p.values = v.isEmpty ? [] : [v]),
      );
    }
    return Focus(
      onFocusChange: (f) {
        if (f) setState(() => _selParam = k);
      },
      child: TextEntry(
        label: '',
        hint: inp.optional ? 'optional' : 'value (vector: separate by ;)',
        value: p.values.join('; '),
        onChanged: (v) => p.values = v.trim().isEmpty ? [] : v.split(';').map((e) => e.trim()).toList(),
      ),
    );
  }
}
