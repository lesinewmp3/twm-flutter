import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';

/// Sampling setup assistant (TWM guide figure 3.25): computes sampling rate
/// and samples count for coherent sampling of a fundamental frequency.
Future<({double fs, int n})?> showSamplingAssistant(BuildContext context, double fs, int n) =>
    showDialog<({double fs, int n})>(
      context: context,
      builder: (_) => AppScope(state: AppScope.read(context), child: _Assistant(fs, n)),
    );

class _Assistant extends StatefulWidget {
  final double fs;
  final int n;
  const _Assistant(this.fs, this.n);
  @override
  State<_Assistant> createState() => _AssistantState();
}

class _AssistantState extends State<_Assistant> {
  double fr = 50, p = 1, q = 1, offset = 0;
  late double minFs = widget.fs;
  double fsTol = 0.1; // relative tolerance of max fs
  double tMin = 0.1, tMax = 1;
  double periodsMin = 0, periodsMax = 0;
  double maxErr = 1e-6;
  double timeout = 10;
  late double fs = widget.fs;
  late int n = widget.n;
  String _msg = '';
  bool _err = false;
  bool _busy = false;

  double get f0 => fr * p / q + offset;

  void _rough() {
    final st = AppScope.read(context);
    final caps = st.settings.digitizer;
    var tmin = tMin, tmax = tMax;
    if (periodsMin > 0) tmin = periodsMin / f0;
    if (periodsMax > 0) tmax = periodsMax / f0;
    fs = minFs;
    final periods = math.max(1, (tmin * f0).ceil());
    n = (periods / f0 * fs).round();
    final t = n / fs;
    setState(() {
      _err = t > tmax;
      _msg =
          'Rough setup (not coherent): fs = ${formatNum(fs)} Sa/s, N = $n, time ${formatNum(t)} s\n'
          'periods: ${formatNum(t * f0)}, DFT bin ${formatNum(fs / n)} Hz, bins per period ${formatNum(n / (t * f0))}\n'
          'digitizer: ${caps.type.label}';
    });
  }

  Future<void> _coherent() async {
    final st = AppScope.read(context);
    setState(() {
      _busy = true;
      _msg = 'Searching coherent setup (GNU Octave: twm_find_coherent)...';
      _err = false;
    });
    var tmin = tMin, tmax = tMax;
    if (periodsMin > 0) tmin = periodsMin / f0;
    if (periodsMax > 0) tmax = periodsMax / f0;
    try {
      // sampling rate grid of the digitizer (struct 'rate' of twm_find_coherent.m)
      final caps = (await st.backend.testDigitizer(st.settings.digitizer)).capabilities;
      if (caps == null) throw 'digitizer capabilities not available';
      final rate = <String, Object?>{
        if (caps.stepMode == SampleRateStepMode.constPeriod && caps.tsStep.isFinite)
          'Ts_step': caps.tsStep
        else
          'fs_step': caps.fsStep.isFinite && caps.fsStep > 0 ? caps.fsStep : 1e-6,
        'adc_fs_min': caps.minFs,
        'adc_fs_max': caps.maxFs,
        'fs_min': minFs,
        'fs_rel_tol': fsTol,
      };
      final r = await st.backend.findCoherent(f0, tmin, tmax, rate, maxErr, timeout);
      setState(() {
        fs = r.fs;
        n = r.n;
        _msg =
            'Coherent setup: fs = ${formatNum(fs)} Sa/s, N = $n, time ${formatNum(n / fs)} s\n'
            'periods: ${formatNum(n / fs * f0)}, error ${r.err}';
      });
    } catch (e) {
      // fallback: integer periods with fs adjusted to the digitizer step
      final periods = math.max(1, (tmin * f0).ceil());
      final nn = (periods * minFs / f0).round();
      final ff = nn * f0 / periods;
      setState(() {
        fs = ff;
        n = nn;
        _err = true;
        _msg =
            'Octave search failed ($e).\nSimple solution: fs = ${formatNum(ff)} Sa/s, N = $nn '
            '($periods periods) - check that the digitizer can set this rate.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sampling setup assistant'),
    content: SizedBox(
      width: 760,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Group(
              title: 'Fundamental frequency',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FieldRow([
                    NumField(
                      label: 'Reference frequency fr',
                      unit: 'Hz',
                      value: fr,
                      width: 180,
                      onChanged: (v) => setState(() => fr = v),
                    ),
                    NumField(label: 'P', value: p, width: 80, onChanged: (v) => setState(() => p = v)),
                    NumField(label: 'Q', value: q, width: 80, min: 1e-12, onChanged: (v) => setState(() => q = v)),
                    NumField(
                      label: 'Offset',
                      unit: 'Hz',
                      value: offset,
                      width: 120,
                      onChanged: (v) => setState(() => offset = v),
                    ),
                    Text('f0 = fr·P/Q + offset = ${formatNum(f0)} Hz'),
                  ]),
                ],
              ),
            ),
            Group(
              title: 'Search range',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FieldRow([
                    NumField(label: 'Minimum fs', unit: 'Sa/s', value: minFs, width: 160, onChanged: (v) => minFs = v),
                    NumField(
                      label: 'fs max tolerance',
                      unit: '-',
                      value: fsTol,
                      width: 140,
                      onChanged: (v) => fsTol = v,
                    ),
                  ]),
                  FieldRow([
                    NumField(
                      label: 'Min integration t.',
                      unit: 's',
                      value: tMin,
                      width: 160,
                      onChanged: (v) => tMin = v,
                    ),
                    NumField(
                      label: 'Max integration t.',
                      unit: 's',
                      value: tMax,
                      width: 160,
                      onChanged: (v) => tMax = v,
                    ),
                    NumField(
                      label: 'Min periods (0=off)',
                      value: periodsMin,
                      width: 150,
                      onChanged: (v) => periodsMin = v,
                    ),
                    NumField(
                      label: 'Max periods (0=off)',
                      value: periodsMax,
                      width: 150,
                      onChanged: (v) => periodsMax = v,
                    ),
                  ]),
                  FieldRow([
                    NumField(label: 'Max setup error', value: maxErr, width: 160, onChanged: (v) => maxErr = v),
                    NumField(
                      label: 'Max timeout',
                      unit: 's',
                      value: timeout,
                      width: 140,
                      onChanged: (v) => timeout = v,
                    ),
                  ]),
                ],
              ),
            ),
            Row(
              children: [
                OutlinedButton(onPressed: _busy ? null : _rough, child: const Text('FIND ROUGH')),
                const SizedBox(width: 8),
                FilledButton.tonal(onPressed: _busy ? null : _coherent, child: const Text('FIND COHERENT')),
                if (_busy) const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
              ],
            ),
            const SizedBox(height: 8),
            MessageBox(_msg, error: _err, height: 90),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, (fs: fs, n: n)), child: const Text('Apply')),
    ],
  );
}
