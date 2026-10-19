import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import 'about_dialog.dart';
import 'batch_dialog.dart';
import 'console_view.dart';
import 'corrections_dialog.dart';
import 'digitizer_dialog.dart';
import 'fft_viewer.dart';
import 'live_view.dart';
import 'measurement_dialog.dart';
import 'octave_dialog.dart';
import 'online_view.dart';
import 'record_viewer.dart';
import 'results_view.dart';
import 'server_dialog.dart';

/// Main panel of TWM (guide figure 3.3) extended by TPQA functions.
class MainScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const MainScreen({super.key, required this.onToggleTheme});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  bool _showErrors = true;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _start({bool setup = false}) async {
    final st = AppScope.read(context);
    if (setup) {
      final ok = await showMeasurementDialog(context);
      if (!ok || !mounted) return;
    }
    final m = st.settings.measurement;
    if (m.folder.trim().isEmpty && (m.saveRecords || !m.continuous)) {
      showError(context, 'Select "Folder for measurement data files" in the measurement setup first.');
      return;
    }
    final errs = st.settings.corrections.validate(
      st.settings.digitizer.virtualChannelsCount,
      muxPaths: st.settings.digitizer.multiplexer.enabled ? st.settings.digitizer.multiplexer.sequence : const [],
    );
    if (errs.isNotEmpty) {
      final go = await confirm(
        context,
        'Transducers configuration',
        'There are problems in the HW corrections setup:\n\n${errs.join('\n')}\n\nStart anyway?',
        ok: 'Start',
      );
      if (!go || !mounted) return;
    }
    try {
      if (m.saveRecords || !m.continuous) {
        final coll = await st.backend.collidingFiles(m);
        if (coll.isNotEmpty) {
          if (!mounted) return;
          final del = await confirm(
            context,
            'Clear last measurement session data?',
            'Measurement folder already contains data. Following files will be DELETED:\n\n'
                '${coll.take(200).join('\n')}${coll.length > 200 ? '\n... (${coll.length} files)' : ''}',
            ok: 'Delete and start',
          );
          if (!del) return;
          await st.backend.clearSession(m);
        }
      }
      await st.startMeasurement();
      // without processing there are no QWTB results to watch - show live data
      if (!m.processingEnabled && _tabs.index == 0) _tabs.animateTo(2);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final busy = st.measuring;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TWM - TracePQM Wattmeter'),
        actions: [
          Center(child: Text(st.backend.description, style: theme.textTheme.bodySmall)),
          IconButton(
            tooltip: 'Light/dark theme',
            onPressed: widget.onToggleTheme,
            icon: const Icon(Icons.brightness_6),
          ),
          IconButton(tooltip: 'About', onPressed: () => showTwmAbout(context), icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Btn(Icons.memory, 'Digitizer', busy ? null : () => showDigitizerDialog(context)),
                _Btn(Icons.functions, 'Octave/Matlab', () => showOctaveDialog(context)),
                _Btn(Icons.tune, 'HW Corrections', busy ? null : () => showCorrectionsDialog(context)),
                const SizedBox(width: 12),
                _Btn(
                  Icons.calculate,
                  'START QWTB CALC',
                  busy ? null : () => showBatchDialog(context),
                  color: Colors.blue.shade100,
                ),
                _Btn(
                  Icons.settings,
                  'SETUP MEASUREMENT',
                  busy ? null : () => showMeasurementDialog(context),
                  color: Colors.yellow.shade200,
                ),
                _Btn(Icons.play_arrow, 'START', busy ? null : () => _start(), color: Colors.green.shade300),
                _Btn(
                  Icons.playlist_play,
                  'SETUP & START',
                  busy ? null : () => _start(setup: true),
                  color: Colors.lightGreen.shade200,
                ),
                _Btn(Icons.stop, 'STOP', busy || st.processing ? () => st.stop() : null, color: Colors.red.shade300),
                const SizedBox(width: 12),
                _Btn(Icons.show_chart, 'VIEW RECORD', () => showRecordViewer(context)),
                _Btn(Icons.bar_chart, 'VIEW FFT', () => showFftViewer(context)),
                _Btn(Icons.lan, 'Server', () => showServerDialog(context)),
              ],
            ),
          ),
          _StatusBar(st),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: const [
              Tab(text: 'QWTB results'),
              Tab(text: 'RAW'),
              Tab(text: 'Live waveforms'),
              Tab(text: 'On-line analysis (TPQA)'),
              Tab(text: 'Console'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [const ResultsView(), _RawView(st), const LiveView(), const OnlineView(), const ConsoleView()],
            ),
          ),
          _ErrorPanel(st, expanded: _showErrors, onToggle: () => setState(() => _showErrors = !_showErrors)),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  const _Btn(this.icon, this.label, this.onPressed, {this.color});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: dark ? null : color,
        foregroundColor: dark ? null : (color != null ? Colors.black87 : null),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final AppState st;
  const _StatusBar(this.st);

  @override
  Widget build(BuildContext context) {
    final rec = st.record > 0 ? 'record ${st.record}${st.records > 0 ? '/${st.records}' : ''}' : '';
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.black,
      child: Row(
        children: [
          Expanded(
            child: Text(
              st.status,
              style: TextStyle(
                fontFamily: 'monospace',
                color: st.measuring ? Colors.yellowAccent : Colors.lightGreenAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (st.processing)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Text(
                'PROCESSING',
                style: TextStyle(color: Colors.orangeAccent, fontFamily: 'monospace'),
              ),
            ),
          Text(
            rec,
            style: const TextStyle(color: Colors.white70, fontFamily: 'monospace'),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 200,
            child: LinearProgressIndicator(
              value: st.measuring ? st.progress : 0,
              minHeight: 10,
              backgroundColor: Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }
}

class _RawView extends StatelessWidget {
  final AppState st;
  const _RawView(this.st);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: st.settings.measurement.processing.mode != ProcessingMode.raw
        ? const Center(child: Text('RAW processing mode is not selected (see Processing setup).'))
        : MessageBox(st.rawOutput.isEmpty ? '(no output yet)' : st.rawOutput, height: double.infinity),
  );
}

class _ErrorPanel extends StatelessWidget {
  final AppState st;
  final bool expanded;
  final VoidCallback onToggle;
  const _ErrorPanel(this.st, {required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final has = st.errors.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onToggle,
                icon: Icon(expanded ? Icons.expand_more : Icons.expand_less),
                tooltip: 'Show/hide',
              ),
              Icon(has ? Icons.error : Icons.check_circle, color: has ? Colors.red : Colors.green, size: 18),
              const SizedBox(width: 6),
              Text(has ? 'error (${st.errors.length})' : 'status: no error'),
              const Spacer(),
              if (has) TextButton(onPressed: st.clearErrors, child: const Text('Clear')),
            ],
          ),
          if (expanded && has) MessageBox(st.errors.reversed.join('\n'), error: true, height: 90),
        ],
      ),
    );
  }
}
