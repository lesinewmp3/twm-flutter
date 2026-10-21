import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/paths.dart';
import 'processing_dialog.dart';
import 'sampling_assistant.dart';
import '../l10n.dart';

/// New measurement configuration (TWM guide figure 3.21). Returns true on OK.
Future<bool> showMeasurementDialog(BuildContext context) async =>
    await showScopedDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _MeasDialog(),
    ) ??
    false;

class _MeasDialog extends StatefulWidget {
  const _MeasDialog();
  @override
  State<_MeasDialog> createState() => _MeasDialogState();
}

class _MeasDialogState extends State<_MeasDialog> {
  late MeasurementConfig m = AppScope.read(context).settings.measurement.copy();
  DigitizerCapabilities? _caps;
  String _capsMsg = tr('Querying digitizer capabilities...');
  int _rev = 0;

  @override
  void initState() {
    super.initState();
    _queryCaps();
  }

  Future<void> _queryCaps() async {
    final st = AppScope.read(context);
    final r = await st.backend.testDigitizer(st.settings.digitizer);
    if (!mounted) return;
    setState(() {
      _caps = r.capabilities;
      _capsMsg = r.ok
          ? '${st.settings.digitizer.type.label}: fs ${formatNum(_caps!.minFs)} - ${formatNum(_caps!.maxFs)} Sa/s, '
                '${tr('max')} ${_caps!.maxSamplesCount} ${tr('samples')}'
          : '${tr('Digitizer not available')}: ${r.message}';
      if (r.ok) st.channelIdns = r.channelIdns;
    });
  }

  double _autoAperture(AppSettings s) {
    final d = s.digitizer.hp3458a;
    if (s.digitizer.type != DigitizerType.hp3458a) return m.aperture;
    switch (d.apertureMode) {
      case Dmm3458ApertureMode.manual:
        return m.aperture;
      case Dmm3458ApertureMode.table:
        final rules = [...d.apertureTable]..sort((a, b) => a.fsMax.compareTo(b.fsMax));
        for (final r in rules) {
          if (m.fs <= r.fsMax) return r.aperture;
        }
        return rules.isEmpty ? m.aperture : rules.last.aperture;
      case Dmm3458ApertureMode.maximum:
        // 3458A: sampling period must exceed aperture + processing time
        final ts = 1 / m.fs;
        final reserve = ts > 123e-6 ? 23e-6 : 10e-6;
        return (ts - reserve).clamp(500e-9, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final s = st.settings;
    final caps = _caps;
    final now = DateTime.now();
    final fullPath = m.folder.isEmpty ? '(select folder)' : joinPath(m.folder, m.resolveName(now));
    final aperAuto =
        s.digitizer.type == DigitizerType.hp3458a && s.digitizer.hp3458a.apertureMode != Dmm3458ApertureMode.manual;
    final coerced = caps?.coerceFs(m.fs);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1000,
        height: 800,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogHeader(tr('New measurement')),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  key: ValueKey(_rev),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_capsMsg, style: Theme.of(context).textTheme.bodySmall),
                    Group(
                      title: tr('Sampling'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FieldRow([
                            if (caps != null && caps.fixedRates.isNotEmpty)
                              Choice<double>(
                                label: tr('Sampling rate'),
                                value: caps.coerceFs(m.fs),
                                items: caps.fixedRates,
                                width: 180,
                                itemLabel: (v) => '${formatNum(v)} Sa/s',
                                onChanged: (v) => setState(() => m.fs = v),
                              )
                            else
                              NumField(
                                label: tr('Sampling rate'),
                                unit: 'Sa/s',
                                value: m.fs,
                                min: caps?.minFs ?? 0.001,
                                max: caps?.maxFs,
                                width: 180,
                                onChanged: (v) => setState(() => m.fs = v),
                              ),
                            if (coerced != null && (coerced - m.fs).abs() > 1e-9 * m.fs)
                              Text('actual: ${formatNum(coerced)} Sa/s', style: const TextStyle(color: Colors.orange)),
                            NumField(
                              label: aperAuto ? tr('Aperture (auto)') : tr('Aperture time'),
                              unit: 's',
                              value: aperAuto ? _autoAperture(s) : m.aperture,
                              enabled: (caps?.hasAperture ?? true) && !aperAuto,
                              min: caps?.aperMin,
                              max: caps?.aperMax,
                              width: 160,
                              onChanged: (v) => setState(() => m.aperture = v),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                final r = await showSamplingAssistant(context, m.fs, m.samplesCount);
                                if (r != null) {
                                  setState(() {
                                    m.fs = r.fs;
                                    m.samplesCount = r.n;
                                    _rev++;
                                  });
                                }
                              },
                              icon: const Icon(Icons.auto_fix_high),
                              label: Text(tr('Sampling setup assistant')),
                            ),
                          ]),
                          FieldRow([
                            NumField(
                              label: tr('Samples count'),
                              value: m.samplesCount.toDouble(),
                              integer: true,
                              min: 1,
                              max: caps?.maxSamplesCount.toDouble(),
                              width: 160,
                              onChanged: (v) => setState(() {
                                m.samplesCount = v.round();
                                _rev++;
                              }),
                            ),
                            NumField(
                              label: tr('Measurement time'),
                              unit: 's',
                              value: m.measurementTime,
                              min: 0,
                              width: 160,
                              onChanged: (v) => setState(() {
                                m.samplesCount = (v * m.fs).round().clamp(1, 1 << 40);
                                _rev++;
                              }),
                            ),
                            NumField(
                              label: tr('Records count'),
                              value: m.recordsCount.toDouble(),
                              integer: true,
                              min: 1,
                              width: 130,
                              enabled: !m.continuous,
                              onChanged: (v) => setState(() => m.recordsCount = v.round()),
                            ),
                            NumField(
                              label: tr('Pre-record settling time'),
                              unit: 's',
                              value: m.preRecordDelay,
                              min: 0,
                              width: 190,
                              onChanged: (v) => m.preRecordDelay = v,
                            ),
                            NumField(
                              label: tr('Sub-records count'),
                              value: m.subRecordsCount.toDouble(),
                              integer: true,
                              min: 1,
                              width: 150,
                              onChanged: (v) => setState(() => m.subRecordsCount = v.round()),
                            ),
                          ]),
                          FieldRow([
                            Check(
                              label: tr('Continuous acquisition until STOP (TPQA)'),
                              value: m.continuous,
                              onChanged: (v) => setState(() => m.continuous = v),
                            ),
                            if (m.continuous)
                              Check(
                                label: tr('Save sampled data'),
                                value: m.saveRecords,
                                onChanged: (v) => setState(() => m.saveRecords = v),
                              ),
                          ]),
                          Text(
                            trf('DFT bin: {0} Hz, record length: {1} s', [
                                  formatNum(m.fs / m.samplesCount),
                                  formatNum(m.measurementTime),
                                ]) +
                                (m.subRecordsCount > 1 ? ' x ${m.subRecordsCount} ${tr('sub-records')}' : ''),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (m.samplesCount / m.fs < 0.1)
                            Text(
                              tr(
                                'Less than 5 periods of 50 Hz in the record: mains frequency results '
                                '(f, harmonics, THD, power) will be wrong.',
                              ),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                            ),
                        ],
                      ),
                    ),
                    Group(
                      title: tr('Trigger and ranges'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FieldRow([
                            Choice<TriggerSource>(
                              label: tr('Trigger mode'),
                              value: m.trigger.source,
                              width: 160,
                              items: [
                                TriggerSource.immediate,
                                if (caps?.hasExtTrig ?? true) TriggerSource.external,
                                if (caps?.hasLevelTrig ?? true) TriggerSource.level,
                              ],
                              itemLabel: (t) => tr(TriggerConfig(source: t).modeName),
                              onChanged: (v) => setState(() => m.trigger.source = v),
                            ),
                            if (m.trigger.source != TriggerSource.immediate)
                              Choice<TriggerSlope>(
                                label: tr('Slope'),
                                value: m.trigger.slope,
                                items: TriggerSlope.values,
                                width: 130,
                                itemLabel: (v) => v == TriggerSlope.positive ? 'POS' : 'NEG',
                                onChanged: (v) => setState(() => m.trigger.slope = v),
                              ),
                            if (m.trigger.source == TriggerSource.level) ...[
                              Choice<TriggerCoupling>(
                                label: tr('Coupling'),
                                value: m.trigger.coupling,
                                items: TriggerCoupling.values,
                                width: 120,
                                itemLabel: (v) => v.name.toUpperCase(),
                                onChanged: (v) => setState(() => m.trigger.coupling = v),
                              ),
                              NumField(
                                label: tr('Level (1. channel)'),
                                unit: 'V',
                                value: m.trigger.level,
                                width: 160,
                                onChanged: (v) => m.trigger.level = v,
                              ),
                            ],
                          ]),
                          FieldRow([
                            Choice<RangeMode>(
                              label: tr('Voltage range selection'),
                              value: m.rangeMode,
                              items: RangeMode.values,
                              width: 220,
                              itemLabel: (r) => {
                                RangeMode.keepDefaults: tr('Keep defaults'),
                                RangeMode.allSame: tr('Same for all channels'),
                                RangeMode.oddEven: tr('Odd/even channels'),
                              }[r]!,
                              onChanged: (v) => setState(() => m.rangeMode = v),
                            ),
                            if (m.rangeMode == RangeMode.allSame)
                              _rangeField('Range', m.rangeAll, caps, (v) => m.rangeAll = v),
                            if (m.rangeMode == RangeMode.oddEven) ...[
                              _rangeField('Range odd (1,3,..)', m.rangeOdd, caps, (v) => m.rangeOdd = v),
                              _rangeField('Range even (2,4,..)', m.rangeEven, caps, (v) => m.rangeEven = v),
                            ],
                          ]),
                        ],
                      ),
                    ),
                    Group(
                      title: tr('Measurement data'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PathField(
                            label: tr('Folder for measurement data files'),
                            value: m.folder,
                            backend: st.backend,
                            mode: BrowseMode.folder,
                            onChanged: (v) => setState(() => m.folder = v),
                          ),
                          FieldRow([
                            TextEntry(
                              label: tr('Measurement name base'),
                              value: m.nameBase,
                              width: 300,
                              hint: tr('variables: %id% %date% %time%'),
                              onChanged: (v) => setState(() => m.nameBase = v),
                            ),
                            NumField(
                              label: tr('Measurement number (%id%)'),
                              value: m.measurementId.toDouble(),
                              integer: true,
                              min: 0,
                              width: 200,
                              onChanged: (v) => setState(() => m.measurementId = v.round()),
                            ),
                          ]),
                          SelectableText(
                            '${tr('Full measurement base path')}: $fullPath',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          TextEntry(
                            label: tr('Measurement comment'),
                            value: m.comment,
                            maxLines: 3,
                            onChanged: (v) => m.comment = v,
                          ),
                        ],
                      ),
                    ),
                    Group(
                      title: tr('Processing'),
                      child: FieldRow([
                        Check(
                          label: tr('Enable result calculation'),
                          value: m.processingEnabled,
                          onChanged: (v) => setState(() => m.processingEnabled = v),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final r = await showProcessingDialog(context, m.processing);
                            if (r != null) setState(() => m.processing = r);
                          },
                          icon: const Icon(Icons.calculate),
                          label: Text(tr('Processing setup')),
                        ),
                        Text(
                          m.processing.mode == ProcessingMode.raw
                              ? 'RAW m-code'
                              : '${m.processing.algorithmId}, ${tr('uncertainty')}: ${tr(m.processing.uncertainty.key)}',
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('CANCEL'))),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      if (aperAuto) m.aperture = _autoAperture(s);
                      if (caps != null) m.fs = caps.coerceFs(m.fs);
                      st.update((x) => x.measurement = m);
                      Navigator.pop(context, true);
                    },
                    child: Text(tr('OK')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeField(String label, double v, DigitizerCapabilities? caps, ValueChanged<double> f) =>
      caps != null && caps.ranges.isNotEmpty
      ? Choice<double>(
          label: label,
          value: v,
          items: {...caps.ranges, v}.toList()..sort(),
          width: 160,
          itemLabel: (r) => '${formatNum(r)} V',
          onChanged: (x) => setState(() => f(x)),
        )
      : NumField(label: label, unit: 'V', value: v, width: 160, onChanged: f);
}
