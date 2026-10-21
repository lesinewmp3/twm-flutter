import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/rows_editor.dart';
import 'multiplexer_dialog.dart';
import '../l10n.dart';

/// "Digitizer configuration" panel (TWM guide 3.1.4.2, TPQA WB setup and
/// LF-Setup DMMs panels).
Future<void> showDigitizerDialog(BuildContext context) => showScopedDialog(
  context: context,
  barrierDismissible: false,
  builder: (_) => const _DigitizerDialog(),
);

class _DigitizerDialog extends StatefulWidget {
  const _DigitizerDialog();
  @override
  State<_DigitizerDialog> createState() => _DigitizerDialogState();
}

class _DigitizerDialogState extends State<_DigitizerDialog> {
  late DigitizerConfig cfg = AppScope.read(context).settings.digitizer.copy();
  String _info = '';
  String _msg = '';
  bool _msgError = false;
  bool _busy = false;
  List<String> _devices = [];
  Timer? _infoTimer;

  @override
  void initState() {
    super.initState();
    _refreshInfo();
  }

  @override
  void dispose() {
    _infoTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _infoTimer?.cancel();
    _infoTimer = Timer(const Duration(milliseconds: 300), _refreshInfo);
  }

  Future<void> _refreshInfo() async {
    final i = await AppScope.read(context).backend.digitizerInfo(cfg);
    if (mounted) setState(() => _info = i);
  }

  Future<void> _test() async {
    final st = AppScope.read(context);
    setState(() {
      _busy = true;
      _msg = tr('Testing...');
      _msgError = false;
    });
    final r = await st.backend.testDigitizer(cfg);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msgError = !r.ok;
      _msg = r.ok
          ? '${trLines(r.message)}\n\n${tr('Channels')}:\n${r.channelIdns.map((e) => '  $e').join('\n')}'
                '${r.auxIdns.isEmpty ? '' : '\n${tr('Auxiliary HW')}:\n${r.auxIdns.map((e) => '  $e').join('\n')}'}'
                '${r.capabilities == null ? '' : '\n\nfs: ${formatNum(r.capabilities!.minFs)} - ${formatNum(r.capabilities!.maxFs)} Sa/s, '
                          '${tr('max samples')}: ${r.capabilities!.maxSamplesCount}'}'
          : trLines(r.message);
    });
    if (r.ok) st.channelIdns = r.channelIdns;
  }

  Future<void> _selfCal() async {
    final ok = await confirm(
      context,
      tr('Self-calibration'),
      tr(
        'Self-calibration changes the amplitude linearity of the digitizer, so it may alter the digitizer corrections. Continue?',
      ),
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _msg = tr('Self-calibration running...');
    });
    try {
      await AppScope.read(context).backend.selfCalibrate(cfg);
      setState(() => _msg = tr('Self-calibration done.'));
    } catch (e) {
      setState(() {
        _msg = '$e';
        _msgError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1150,
        height: 760,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogHeader(tr('Digitizer configuration')),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 330,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Choice<DigitizerType>(
                            label: tr('Digitizer type'),
                            value: cfg.type,
                            items: st.backend.features.digitizers,
                            itemLabel: (t) => t.label,
                            width: 300,
                            onChanged: (t) {
                              cfg.type = t;
                              _changed();
                            },
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: 300,
                            constraints: const BoxConstraints(minHeight: 120),
                            padding: const EdgeInsets.all(8),
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: Text(trLines(_info), style: const TextStyle(fontSize: 12)),
                          ),
                          const SizedBox(height: 12),
                          Choice<OnCloseAction>(
                            label: tr('On device close'),
                            value: cfg.onClose,
                            items: OnCloseAction.values,
                            itemLabel: (a) =>
                                a == OnCloseAction.immediateReset ? tr('Immediate reset') : tr('Delayed reset'),
                            width: 300,
                            onChanged: (v) => setState(() => cfg.onClose = v),
                          ),
                          if (cfg.onClose == OnCloseAction.delayedReset)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: NumField(
                                label: tr('Delayed reset timeout'),
                                unit: 's',
                                value: cfg.delayedResetTimeout,
                                min: 1,
                                onChanged: (v) => cfg.delayedResetTimeout = v,
                              ),
                            ),
                          Check(
                            label: tr('Force reset on open'),
                            value: cfg.forceResetOnOpen,
                            onChanged: (v) => setState(() => cfg.forceResetOnOpen = v),
                          ),
                          Check(
                            label: tr('Ignore channel overload'),
                            value: cfg.ignoreOverload,
                            onChanged: (v) => setState(() => cfg.ignoreOverload = v),
                          ),
                          const Divider(),
                          Check(
                            label: tr('Enable multiplexer mode (experimental)'),
                            value: cfg.multiplexer.enabled,
                            onChanged: (v) => setState(() => cfg.multiplexer.enabled = v),
                          ),
                          OutlinedButton(
                            onPressed: () async {
                              await showMultiplexerDialog(context, cfg.multiplexer);
                              setState(() {});
                            },
                            child: Text(tr('CONFIG MULTIPLEXER')),
                          ),
                          const SizedBox(height: 8),
                          Text('${tr('Virtual channels')}: ${cfg.virtualChannelsCount}'),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: _page(st)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  FilledButton.tonal(onPressed: _busy ? null : _test, child: Text(tr('TEST'))),
                  const SizedBox(width: 8),
                  FilledButton.tonal(onPressed: _busy ? null : _selfCal, child: const Text('SELF-CAL')),
                  const SizedBox(width: 12),
                  Expanded(child: MessageBox(_msg, error: _msgError, height: 70)),
                  const SizedBox(width: 12),
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      st.update((s) => s.digitizer = cfg);
                      Navigator.pop(context);
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

  Widget _page(AppState st) => switch (cfg.type) {
    DigitizerType.simulated => _simPage(),
    DigitizerType.niScope => _niScopePage(),
    DigitizerType.hp3458a => _dmmPage(),
    DigitizerType.cdaq => _cdaqPage(),
    DigitizerType.keysightDso => _dsoPage(),
    DigitizerType.soundCard => _soundPage(st),
    DigitizerType.ads127l21 => _adsPage(),
  };

  // ----------------------------------------------------------- simulated --

  Widget _simPage() {
    final s = cfg.simulated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow([
          NumField(
            label: tr('Bit resolution'),
            value: s.bits.toDouble(),
            integer: true,
            min: 8,
            max: 31,
            onChanged: (v) => setState(() => s.bits = v.round()),
          ),
          NumField(label: tr('Max sampling rate'), unit: 'Sa/s', value: s.maxFs, min: 1, onChanged: (v) => s.maxFs = v),
          NumField(
            label: tr('Sampling jitter'),
            unit: 's rms',
            value: s.jitterRms,
            min: 0,
            onChanged: (v) => s.jitterRms = v,
          ),
          NumField(
            label: tr('Real-time factor'),
            value: s.realtimeFactor,
            min: 0,
            tooltip: tr('1 = acquisition takes real time, 0 = instant'),
            onChanged: (v) => s.realtimeFactor = v,
          ),
        ]),
        RowsEditor<SimChannelConfig>(
          title: tr('Simulated channels'),
          rows: s.channels,
          create: () => SimChannelConfig(name: 'ch${s.channels.length + 1}'),
          onChanged: _changed,
          rowBuilder: (c, i, ch) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldRow([
                TextEntry(label: tr('Name'), value: ch.name, width: 120, onChanged: (v) => ch.name = v),
                NumField(
                  label: tr('Range'),
                  unit: 'V',
                  value: ch.range,
                  width: 110,
                  min: 1e-6,
                  onChanged: (v) => ch.range = v,
                ),
                NumField(label: 'DC', unit: 'V', value: ch.dc, width: 110, onChanged: (v) => ch.dc = v),
                NumField(
                  label: tr('Noise'),
                  unit: 'V rms',
                  value: ch.noiseRms,
                  width: 130,
                  min: 0,
                  onChanged: (v) => ch.noiseRms = v,
                ),
                NumField(
                  label: tr('Time shift'),
                  unit: 's',
                  value: ch.timeShift,
                  width: 120,
                  onChanged: (v) => ch.timeShift = v,
                ),
              ]),
              // disturbance in every record (UPS transfer, sag, interruption)
              FieldRow([
                Check(
                  label: tr('Event (sag / interruption)'),
                  value: ch.event != null,
                  onChanged: (v) => setState(() => ch.event = v ? SimEvent() : null),
                ),
                if (ch.event != null) ...[
                  NumField(
                    label: tr('Event start'),
                    unit: 's',
                    value: ch.event!.start,
                    width: 130,
                    min: 0,
                    onChanged: (v) => ch.event!.start = v,
                  ),
                  NumField(
                    label: tr('Event duration'),
                    unit: 's',
                    value: ch.event!.duration,
                    width: 150,
                    min: 0,
                    onChanged: (v) => ch.event!.duration = v,
                  ),
                  NumField(
                    label: tr('Residual level'),
                    value: ch.event!.level,
                    width: 150,
                    min: 0,
                    tooltip: tr('0 = interruption, 0.4 = sag to 40 %'),
                    onChanged: (v) => ch.event!.level = v,
                  ),
                  NumField(
                    label: tr('Phase jump'),
                    unit: 'rad',
                    value: ch.event!.phaseJump,
                    width: 130,
                    onChanged: (v) => ch.event!.phaseJump = v,
                  ),
                ],
              ]),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var k = 0; k < ch.harmonics.length; k++)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NumField(
                            label: 'f',
                            unit: 'Hz',
                            value: ch.harmonics[k].freq,
                            width: 100,
                            onChanged: (v) => ch.harmonics[k].freq = v,
                          ),
                          const SizedBox(width: 4),
                          NumField(
                            label: 'A',
                            unit: 'Vpk',
                            value: ch.harmonics[k].amp,
                            width: 140,
                            onChanged: (v) => ch.harmonics[k].amp = v,
                          ),
                          const SizedBox(width: 4),
                          NumField(
                            label: 'φ',
                            unit: 'rad',
                            value: ch.harmonics[k].phase,
                            width: 100,
                            onChanged: (v) => ch.harmonics[k].phase = v,
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => setState(() => ch.harmonics.removeAt(k)),
                          ),
                        ],
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => ch.harmonics.add(SimHarmonic(50.0 * (ch.harmonics.length + 1), 0.01))),
                    icon: const Icon(Icons.add),
                    label: Text(tr('component')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- niScope --

  Widget _niScopePage() {
    final n = cfg.niScope;
    final t = n.trigger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow([
          Choice<NiScopeAcquisitionType>(
            label: tr('Acquisition type'),
            value: n.acquisitionType,
            items: NiScopeAcquisitionType.values,
            width: 230,
            itemLabel: (v) => tr(v.label),
            onChanged: (v) => setState(() => n.acquisitionType = v),
          ),
        ]),
        RowsEditor<NiScopeChannelConfig>(
          title: tr('ADC Channels (NI 5922 cards, channel ID from 0)'),
          rows: n.channels,
          create: () => NiScopeChannelConfig(
            resource: n.channels.isEmpty ? 'PXI1Slot2' : n.channels.last.resource,
            channelId: n.channels.isEmpty ? 0 : (n.channels.last.channelId + 1) % 2,
          ),
          onChanged: _changed,
          rowBuilder: (c, i, ch) => FieldRow([
            TextEntry(label: tr('Resource'), value: ch.resource, width: 120, onChanged: (v) => ch.resource = v),
            NumField(
              label: tr('Channel ID'),
              value: ch.channelId.toDouble(),
              width: 90,
              integer: true,
              min: 0,
              max: 1,
              onChanged: (v) => ch.channelId = v.round(),
            ),
            NumField(label: tr('Range'), unit: 'Vpk', value: ch.range, width: 110, onChanged: (v) => ch.range = v),
            Choice<NiScopeInputZ>(
              label: tr('Input Z'),
              value: ch.inputZ,
              width: 110,
              items: NiScopeInputZ.values,
              itemLabel: (z) => z == NiScopeInputZ.ohm50 ? '50 Ω' : '1 MΩ',
              onChanged: (v) async {
                if (v == NiScopeInputZ.ohm50 &&
                    !await confirm(
                      context,
                      tr('Warning'),
                      tr('Applying voltage over 5 V to 50 Ω input may damage the digitizer!'),
                    )) {
                  return;
                }
                setState(() => ch.inputZ = v);
              },
            ),
            Choice<NiScopeCoupling>(
              label: tr('Coupling'),
              value: ch.coupling,
              width: 100,
              items: NiScopeCoupling.values,
              itemLabel: (c) => c.name.toUpperCase(),
              onChanged: (v) => setState(() => ch.coupling = v),
            ),
            NumField(label: tr('Offset'), unit: 'V', value: ch.offset, width: 100, onChanged: (v) => ch.offset = v),
            NumField(
              label: tr('Probe att.'),
              value: ch.probeAttenuation,
              width: 90,
              onChanged: (v) => ch.probeAttenuation = v,
            ),
            NumField(
              label: tr('Max input f'),
              unit: 'Hz',
              value: ch.maxInputFrequency,
              width: 120,
              tooltip: tr('-1 = default bandwidth'),
              onChanged: (v) => ch.maxInputFrequency = v,
            ),
          ]),
        ),
        Group(
          title: tr('Clock and acquisition'),
          child: FieldRow([
            NumField(
              label: tr('External clock'),
              unit: 'Hz',
              value: n.extClockHz,
              min: 0,
              width: 160,
              tooltip: tr('0 = internal clock; e.g. 10M to lock PLL to external reference'),
              onChanged: (v) => n.extClockHz = v,
            ),
            Choice<NiScopeClockSource>(
              label: tr('External clock mode'),
              value: n.extClockSource,
              items: NiScopeClockSource.values,
              itemLabel: (s) => {
                NiScopeClockSource.clkIn: 'VAL_CLK_IN',
                NiScopeClockSource.pxiClk: 'VAL_PXI_CLOCK',
                NiScopeClockSource.pfi0: 'VAL_PFI_0',
                NiScopeClockSource.pfi1: 'VAL_PFI_1',
                NiScopeClockSource.none: 'VAL_NO_SOURCE',
              }[s]!,
              onChanged: (v) => setState(() => n.extClockSource = v),
            ),
            NumField(
              label: tr('Fetch timeout'),
              unit: 's',
              value: n.fetchTimeout,
              width: 120,
              onChanged: (v) => n.fetchTimeout = v,
            ),
            Check(
              label: tr('Use streaming mode'),
              value: n.streaming,
              onChanged: (v) => setState(() => n.streaming = v),
            ),
          ]),
        ),
        Group(
          title: tr('Trigger (advanced, TPQA)'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldRow([
                Choice<NiScopeTriggerType>(
                  label: tr('Trigger type'),
                  value: t.type,
                  items: NiScopeTriggerType.values,
                  width: 160,
                  onChanged: (v) => setState(() => t.type = v),
                ),
                TextEntry(label: tr('Trigger source'), value: t.source, width: 150, onChanged: (v) => t.source = v),
                NumField(
                  label: tr('Ref. position'),
                  unit: '%',
                  value: t.refPosition,
                  width: 120,
                  onChanged: (v) => t.refPosition = v,
                ),
                NumField(
                  label: tr('Holdoff'),
                  unit: 's',
                  value: t.holdoff,
                  width: 110,
                  onChanged: (v) => t.holdoff = v,
                ),
                NumField(label: tr('Delay'), unit: 's', value: t.delay, width: 110, onChanged: (v) => t.delay = v),
              ]),
              FieldRow([
                NumField(
                  label: tr('Hysteresis'),
                  unit: 'V',
                  value: t.hysteresis,
                  width: 120,
                  onChanged: (v) => t.hysteresis = v,
                ),
                Choice<bool>(
                  label: tr('Window mode'),
                  value: t.windowEntering,
                  items: const [true, false],
                  width: 130,
                  itemLabel: (b) => b ? tr('Entering') : tr('Leaving'),
                  onChanged: (v) => setState(() => t.windowEntering = v),
                ),
                NumField(
                  label: tr('Low level window'),
                  unit: 'V',
                  value: t.lowLevel,
                  width: 150,
                  onChanged: (v) => t.lowLevel = v,
                ),
                NumField(
                  label: tr('High level window'),
                  unit: 'V',
                  value: t.highLevel,
                  width: 150,
                  onChanged: (v) => t.highLevel = v,
                ),
              ]),
              Text(
                tr(
                  'Level/slope/coupling of the basic trigger are set in the measurement setup. '
                  'Parameters above are used for the trigger types not available in TWM (TPQA).',
                ),
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------- 3458A / 8588A --

  Widget _dmmPage() {
    final d = cfg.hp3458a;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RowsEditor<DmmChannelConfig>(
          title: tr('DMM Channels (first = MASTER)'),
          rows: d.channels,
          create: () => DmmChannelConfig(visa: 'GPIB0::${22 + d.channels.length}::INSTR'),
          onChanged: _changed,
          rowBuilder: (c, i, ch) => FieldRow([
            TextEntry(label: 'VISA', value: ch.visa, width: 220, onChanged: (v) => ch.visa = v),
            Choice<double>(
              label: tr('Range [Vpk]'),
              value: ch.range,
              width: 120,
              items: const [0.1, 1, 10, 100, 1000],
              itemLabel: formatNum,
              onChanged: (v) => setState(() => ch.range = v),
            ),
            Check(label: 'F8588', value: ch.isF8588, onChanged: (v) => setState(() => ch.isF8588 = v)),
          ]),
        ),
        Group(
          title: tr('Digitizing'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldRow([
                Choice<Dmm3458IdnMode>(
                  label: tr('Control DMM descriptor mode'),
                  value: d.idnMode,
                  items: Dmm3458IdnMode.values,
                  width: 230,
                  itemLabel: (m) => {
                    Dmm3458IdnMode.auto: tr('Auto'),
                    Dmm3458IdnMode.sequential: tr('Sequential'),
                    Dmm3458IdnMode.calibrationString: tr('From calibration string'),
                  }[m]!,
                  onChanged: (v) => setState(() => d.idnMode = v),
                ),
                Choice<Dmm3458Mode>(
                  label: tr('DMM digitizing mode'),
                  value: d.mode,
                  items: Dmm3458Mode.values,
                  width: 160,
                  itemLabel: (m) => m.name.toUpperCase(),
                  onChanged: (v) => setState(() => d.mode = v),
                ),
                Choice<Dmm3458Sync>(
                  label: tr('Synchronization mode'),
                  value: d.sync,
                  items: Dmm3458Sync.values,
                  width: 360,
                  itemLabel: (m) => m.label,
                  onChanged: (v) => setState(() => d.sync = v),
                ),
              ]),
              if (d.sync == Dmm3458Sync.masterSlaveAwg || d.sync == Dmm3458Sync.allAwg)
                FieldRow([
                  Choice<AwgType>(
                    label: tr('AWG type'),
                    value: d.awgType,
                    items: AwgType.values,
                    width: 200,
                    onChanged: (v) => setState(() => d.awgType = v),
                  ),
                  TextEntry(
                    label: tr('AWG VISA'),
                    value: d.awgVisa,
                    width: 220,
                    onChanged: (v) => d.awgVisa = v,
                    enabled: d.awgType != AwgType.dummy,
                  ),
                ]),
              if (d.sync == Dmm3458Sync.allTimer)
                FieldRow([
                  Choice<CounterType>(
                    label: tr('Counter type'),
                    value: d.counterType,
                    items: CounterType.values,
                    width: 200,
                    onChanged: (v) => setState(() => d.counterType = v),
                  ),
                  TextEntry(
                    label: tr('Counter VISA'),
                    value: d.counterVisa,
                    width: 220,
                    onChanged: (v) => d.counterVisa = v,
                  ),
                ]),
              FieldRow([
                Check(
                  label: tr('Use streaming mode'),
                  value: d.streaming,
                  onChanged: (v) => setState(() => d.streaming = v),
                ),
                Check(
                  label: tr('Measure temperature'),
                  value: d.measureTemperature,
                  onChanged: (v) => setState(() => d.measureTemperature = v),
                ),
                Check(
                  label: tr('Disable display'),
                  value: d.disableDisplay,
                  onChanged: (v) => setState(() => d.disableDisplay = v),
                ),
              ]),
              FieldRow([
                Choice<Dmm3458Format>(
                  label: tr('Output format'),
                  value: d.format,
                  items: Dmm3458Format.values,
                  width: 150,
                  itemLabel: (f) => f == Dmm3458Format.auto ? tr('Auto') : f.name.toUpperCase(),
                  onChanged: (v) => setState(() => d.format = v),
                ),
                Choice<Dmm3458Memory>(
                  label: tr('Memory mode'),
                  value: d.memory,
                  items: Dmm3458Memory.values,
                  width: 170,
                  itemLabel: (m) => {
                    Dmm3458Memory.standard: tr('Standard'),
                    Dmm3458Memory.option001: tr('Option 001'),
                    Dmm3458Memory.memoryOff: tr('Memory OFF'),
                  }[m]!,
                  onChanged: (v) => setState(() => d.memory = v),
                ),
              ]),
            ],
          ),
        ),
        Group(
          title: tr('Aperture selection'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldRow([
                Choice<Dmm3458ApertureMode>(
                  label: tr('Aperture selection mode'),
                  value: d.apertureMode,
                  items: Dmm3458ApertureMode.values,
                  width: 220,
                  onChanged: (v) => setState(() => d.apertureMode = v),
                ),
              ]),
              if (d.apertureMode == Dmm3458ApertureMode.table)
                RowsEditor<ApertureRule>(
                  title: tr('Aperture auto selection rules (up to fs -> aperture)'),
                  rows: d.apertureTable,
                  create: () => ApertureRule(100000, 1.4e-6),
                  onChanged: _changed,
                  rowBuilder: (c, i, r) => FieldRow([
                    NumField(
                      label: tr('fs max'),
                      unit: 'Sa/s',
                      value: r.fsMax,
                      width: 140,
                      onChanged: (v) => r.fsMax = v,
                    ),
                    NumField(
                      label: tr('Aperture'),
                      unit: 's',
                      value: r.aperture,
                      width: 140,
                      onChanged: (v) => r.aperture = v,
                    ),
                  ]),
                ),
            ],
          ),
        ),
        if (d.hasF8588)
          Group(
            title: tr('Fluke 8588A options'),
            child: FieldRow([
              Choice<String>(
                label: tr('Low pass filter'),
                value: d.f8588Filter,
                width: 160,
                items: const ['OFF', '3MHz', '40MHz'],
                onChanged: (v) => setState(() => d.f8588Filter = v),
              ),
              Check(
                label: tr('Lock to external reference'),
                value: d.f8588ExtRefLock,
                onChanged: (v) => setState(() => d.f8588ExtRefLock = v),
              ),
            ]),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- cDAQ --

  Widget _cdaqPage() {
    final c = cfg.cdaq;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow([
          TextEntry(label: tr('Device address'), value: c.device, width: 200, onChanged: (v) => c.device = v),
          Choice<double>(
            label: tr('Fixed sampling rate'),
            value: c.fixedRate,
            width: 180,
            items: const [50000, 25000, 12500, 10000, 5000, 1000, 39062.5],
            itemLabel: (r) => '${formatNum(r)} Sa/s',
            onChanged: (v) => setState(() => c.fixedRate = v),
          ),
        ]),
        Group(
          title: tr('Channels (NI 9238: ID 0 - 3)'),
          child: Wrap(
            spacing: 12,
            children: [
              for (var id = 0; id < 4; id++)
                Check(
                  label: 'ai$id',
                  value: c.channelIds.contains(id),
                  onChanged: (v) {
                    setState(() {
                      v ? c.channelIds.add(id) : c.channelIds.remove(id);
                      c.channelIds.sort();
                    });
                    _changed();
                  },
                ),
            ],
          ),
        ),
        Group(
          title: tr('Digitizer master clock'),
          child: FieldRow([
            Choice<CdaqClockMode>(
              label: tr('Digitizer master clock mode'),
              value: c.clockMode,
              items: CdaqClockMode.values,
              width: 240,
              itemLabel: (m) => {
                CdaqClockMode.freeRunning: tr('Free running'),
                CdaqClockMode.importMasterClock: tr('Import master clock'),
                CdaqClockMode.exportMasterClock: tr('Export master clock'),
              }[m]!,
              onChanged: (v) => setState(() => c.clockMode = v),
            ),
            TextEntry(
              label: tr('Clock source'),
              value: c.clockSource,
              width: 160,
              onChanged: (v) => c.clockSource = v,
              enabled: c.clockMode == CdaqClockMode.importMasterClock,
            ),
            NumField(
              label: tr('External master clock frequency'),
              unit: 'Hz',
              value: c.extClockHz,
              width: 240,
              enabled: c.clockMode == CdaqClockMode.importMasterClock,
              onChanged: (v) => c.extClockHz = v,
            ),
          ]),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- DSO --

  Widget _dsoPage() {
    final d = cfg.dso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow([TextEntry(label: tr('Scope VISA address'), value: d.visa, width: 420, onChanged: (v) => d.visa = v)]),
        RowsEditor<DsoChannelConfig>(
          title: tr('ADC channels (ID from 1)'),
          rows: d.channels,
          maxRows: 4,
          create: () => DsoChannelConfig(channelId: d.channels.length + 1),
          onChanged: _changed,
          rowBuilder: (c, i, ch) => FieldRow([
            NumField(
              label: tr('Channel ID'),
              value: ch.channelId.toDouble(),
              integer: true,
              min: 1,
              max: 4,
              width: 100,
              onChanged: (v) => ch.channelId = v.round(),
            ),
            NumField(label: tr('Range'), unit: 'Vpk', value: ch.range, width: 120, onChanged: (v) => ch.range = v),
            NumField(label: tr('Offset'), unit: 'V', value: ch.offset, width: 110, onChanged: (v) => ch.offset = v),
            Choice<DsoCoupling>(
              label: tr('Coupling'),
              value: ch.coupling,
              items: DsoCoupling.values,
              width: 130,
              itemLabel: (c) => {
                DsoCoupling.dc1M: tr('DC 1 MΩ'),
                DsoCoupling.ac1M: tr('AC 1 MΩ'),
                DsoCoupling.dc50: tr('DC 50 Ω'),
              }[c]!,
              onChanged: (v) => setState(() => ch.coupling = v),
            ),
          ]),
        ),
        FieldRow([
          NumField(
            label: tr('BW limit'),
            unit: 'Hz',
            value: d.bwLimit,
            width: 140,
            tooltip: tr('-1 = disabled'),
            onChanged: (v) => d.bwLimit = v,
          ),
          Choice<String>(
            label: tr('Bit resolution'),
            value: d.bitResolution,
            width: 150,
            items: const ['Auto', '10', '11', '12', '13', '14', '15', '16'],
            onChanged: (v) => setState(() => d.bitResolution = v),
          ),
          Choice<String>(
            label: tr('Trigger noise reject'),
            value: d.noiseReject,
            width: 170,
            items: const ['Normal', 'ON'],
            onChanged: (v) => setState(() => d.noiseReject = v),
          ),
        ]),
      ],
    );
  }

  // ---------------------------------------------------------- sound card --

  Widget _soundPage(AppState st) {
    final s = cfg.soundCard;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow([
          Choice<String>(
            label: tr('Capture device'),
            value: s.device,
            width: 360,
            items: {s.device, ..._devices}.toList(),
            onChanged: (v) => setState(() => s.device = v),
          ),
          OutlinedButton(
            onPressed: () async {
              try {
                final d = await st.backend.enumerateDevices(cfg);
                setState(() => _devices = d);
              } catch (e) {
                if (mounted) showError(context, e);
              }
            },
            child: Text(tr('Enumerate devices')),
          ),
        ]),
        FieldRow([
          Choice<int>(
            label: tr('Channels'),
            value: s.channels,
            items: const [1, 2],
            width: 120,
            onChanged: (v) {
              setState(() => s.channels = v);
              _changed();
            },
          ),
          Choice<int>(
            label: tr('Bits'),
            value: s.bits,
            items: const [16, 24, 32],
            width: 120,
            onChanged: (v) => setState(() => s.bits = v),
          ),
          NumField(
            label: tr('Full scale (assumed)'),
            unit: 'Vpk',
            value: s.range,
            width: 180,
            onChanged: (v) => s.range = v,
          ),
        ]),
        Text(
          tr(
            'Sound cards usually have AC coupled inputs: usable for phase, THD and spectrum, '
            'not for DC or non-stationary signals.',
          ),
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- ADS127 --

  Widget _adsPage() {
    final a = cfg.ads127;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow([
          TextEntry(label: tr('VISA / port'), value: a.visa, width: 220, onChanged: (v) => a.visa = v),
          NumField(
            label: tr('Channels'),
            value: a.channels.toDouble(),
            integer: true,
            min: 1,
            max: 8,
            width: 100,
            onChanged: (v) {
              a.channels = v.round();
              _changed();
            },
          ),
          NumField(label: tr('Range'), unit: 'Vpk', value: a.range, width: 110, onChanged: (v) => a.range = v),
        ]),
        FieldRow([
          Choice<String>(
            label: tr('Input mode'),
            value: a.inputMode,
            items: const ['SE', 'DIFF'],
            width: 130,
            onChanged: (v) => setState(() => a.inputMode = v),
          ),
          Choice<String>(
            label: tr('Input impedance'),
            value: a.inputZ,
            items: const ['1M', '10M', 'HiZ'],
            width: 150,
            onChanged: (v) => setState(() => a.inputZ = v),
          ),
          Check(
            label: tr('External 10 MHz reference'),
            value: a.extRef,
            onChanged: (v) => setState(() => a.extRef = v),
          ),
        ]),
        Text(
          tr('Experimental CMI digitizer, protocol not publicly documented - driver unverified.'),
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
