import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';

/// Processing configuration panel (TWM guide figures 3.27 - 3.29, TPQA
/// "QWTB processing algorithms"). Returns modified copy or null.
Future<ProcessingSetup?> showProcessingDialog(BuildContext context, ProcessingSetup setup) =>
    showDialog<ProcessingSetup>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppScope(state: AppScope.read(context), child: _ProcDialog(setup.copy())),
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1150,
        height: 800,
        child: DefaultTabController(
          length: 2,
          initialIndex: ps.mode == ProcessingMode.raw ? 0 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DialogHeader(
                'Processing setup',
                bottom: TabBar(
                  onTap: (i) => ps.mode = i == 0 ? ProcessingMode.raw : ProcessingMode.qwtb,
                  tabs: const [
                    Tab(text: 'RAW command'),
                    Tab(text: 'QWTB'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [_raw(), _qwtb()]),
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
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: () => Navigator.pop(context, ps), child: const Text('OK')),
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
        const Text(
          'm-code executed on each record. Loaded data are in structure "data" '
          '(data.y - samples, one column per channel, data.Ts - sampling period, data.corr - corrections). '
          'Printed output appears in the RAW tab of the main window.',
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextEntry(label: 'm-code', value: ps.rawCode, maxLines: 30, onChanged: (v) => ps.rawCode = v),
        ),
        Row(
          children: [
            OutlinedButton(
              onPressed: () async {
                final b = AppScope.read(context).backend;
                final f = await browse(context, b, title: 'Load m-file', extensions: const ['.m']);
                if (f == null) return;
                final t = await b.readText(f);
                setState(() {
                  ps.rawCode = t;
                  _rev++;
                });
              },
              child: const Text('Load from file'),
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
                    Text('List of algorithms', style: Theme.of(context).textTheme.titleSmall),
                    const Spacer(),
                    TextButton(onPressed: _loading ? null : _loadAlgs, child: const Text('RELOAD ALGs')),
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
                    SelectableText('Citation: ${i.citation}', style: const TextStyle(fontSize: 12)),
                  if (i.remarks.isNotEmpty)
                    SelectableText('Remarks: ${i.remarks}', style: const TextStyle(fontSize: 12)),
                  if (i.license.isNotEmpty) Text('License: ${i.license}', style: const TextStyle(fontSize: 12)),
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
                  Text('Outputs: ${i.outputs.map((o) => o.name).join(', ')}', style: const TextStyle(fontSize: 12)),
                  Group(
                    title: 'Parameters of the algorithm',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (params.isEmpty) const Text('(no user parameters)'),
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
                            child: Text('Variable description: ${params[_selParam].desc}'),
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
                            child: const Text('CLEAR PARAMETERS'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
                  const Text('Select an algorithm.'),
                Group(
                  title: 'Processing options',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FieldRow([
                        NumField(
                          label: 'Start offset',
                          unit: 'smpl',
                          value: ps.sampleOffset.toDouble(),
                          integer: true,
                          min: 0,
                          width: 150,
                          onChanged: (v) => ps.sampleOffset = v.round(),
                        ),
                        NumField(
                          label: 'Input data length (0=all)',
                          unit: 'smpl',
                          value: ps.sampleLimit.toDouble(),
                          integer: true,
                          min: 0,
                          width: 200,
                          onChanged: (v) => ps.sampleLimit = v.round(),
                        ),
                        Choice<TimeStampMode>(
                          label: 'Time-stamp handling',
                          value: ps.timeStampMode,
                          items: TimeStampMode.values,
                          width: 200,
                          itemLabel: (m) => const {
                            TimeStampMode.enable: 'Enable',
                            TimeStampMode.disable: 'Disable',
                            TimeStampMode.relative: 'Relative to 1. record',
                          }[m]!,
                          onChanged: (v) => setState(() => ps.timeStampMode = v),
                        ),
                      ]),
                      Check(
                        label: 'Calculate result just once for all records (multi-record algorithms)',
                        value: ps.wholeAverageAtOnce,
                        enabled: i?.supportMultiRecords ?? false,
                        onChanged: (v) => setState(() => ps.wholeAverageAtOnce = v),
                      ),
                      Check(
                        label: 'Calculate uncertainty just once (first record)',
                        value: ps.uncertaintyOnce,
                        onChanged: (v) => setState(() => ps.uncertaintyOnce = v),
                      ),
                      FieldRow([
                        Choice<UncertaintyMode>(
                          label: 'Uncertainty calculation mode',
                          value: ps.uncertainty,
                          width: 220,
                          items: [
                            UncertaintyMode.none,
                            if (i?.uncGuf ?? true) UncertaintyMode.guf,
                            if (i?.uncMcm ?? true) UncertaintyMode.mcm,
                          ],
                          itemLabel: (u) => const {
                            UncertaintyMode.none: 'None',
                            UncertaintyMode.guf: 'GUF (estimator)',
                            UncertaintyMode.mcm: 'Monte Carlo',
                          }[u]!,
                          onChanged: (v) => setState(() => ps.uncertainty = v),
                        ),
                        NumField(
                          label: 'Level of confidence',
                          value: ps.levelOfConfidence,
                          min: 0.5,
                          max: 0.9999,
                          width: 150,
                          onChanged: (v) => ps.levelOfConfidence = v,
                        ),
                        if (ps.uncertainty == UncertaintyMode.mcm)
                          NumField(
                            label: 'Monte Carlo cycles',
                            value: ps.monteCarloCycles.toDouble(),
                            integer: true,
                            min: 10,
                            width: 160,
                            onChanged: (v) => ps.monteCarloCycles = v.round(),
                          ),
                        NumField(
                          label: 'Processing timeout',
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
                Group(
                  title: 'Multicore processing',
                  child: FieldRow([
                    Choice<ExecutionMode>(
                      label: 'QWTB algorithms execution mode',
                      value: ps.execution,
                      items: ExecutionMode.values,
                      width: 260,
                      itemLabel: (m) =>
                          m == ExecutionMode.singleCore ? 'Single-core' : 'Parallel record processing (exp.)',
                      onChanged: (v) => setState(() => ps.execution = v),
                    ),
                    Choice<ParallelMode>(
                      label: 'Parallel mode (Monte Carlo)',
                      value: ps.parallel,
                      items: ParallelMode.values,
                      width: 220,
                      itemLabel: (m) => const {
                        ParallelMode.singlecore: 'Singlecore',
                        ParallelMode.multicore: 'Multicore (parcellfun/parfor)',
                        ParallelMode.multistation: 'Multistation (multicore pkg)',
                      }[m]!,
                      onChanged: (v) => setState(() => ps.parallel = v),
                    ),
                    if (ps.parallel != ParallelMode.singlecore)
                      NumField(
                        label: 'CPU cores',
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
                          label: 'Multistation jobs folder',
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
        itemLabel: (v) => v.isEmpty ? '(default)' : v,
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
