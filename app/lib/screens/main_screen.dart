import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../l10n.dart';
import '../state/app_state.dart';
import '../widgets/fields.dart';
import 'about_dialog.dart';
import 'batch_dialog.dart';
import 'console_view.dart';
import 'corrections_dialog.dart';
import 'digitizer_dialog.dart';
import 'files_page.dart';
import 'fft_viewer.dart';
import 'live_view.dart';
import 'measurement_dialog.dart';
import 'octave_dialog.dart';
import 'online_view.dart';
import 'record_viewer.dart';
import 'results_view.dart';
import 'server_dialog.dart';

enum _Page { measure, results, online, records, files, console }

/// Main window: navigation rail with pages (TWM main panel + TPQA panels),
/// header with measurement actions and status.
class MainScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const MainScreen({super.key, required this.onToggleTheme});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  _Page _page = _Page.measure;
  int _seenErrors = 0;
  int _toastedErrors = -1;

  /// New errors pop up at the bottom (the badge alone is easy to miss).
  void _toastNewErrors(AppState st) {
    if (_toastedErrors < 0) _toastedErrors = st.errorCount; // older ones are in the log
    if (st.errorCount <= _toastedErrors) return;
    _toastedErrors = st.errorCount;
    final msg = trMessage(st.errors.last.replaceFirst(RegExp(r'^\[[0-9:]+\] '), ''));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showError(context, msg);
    });
  }

  /// Checks of the QWTB processing setup against the measurement setup.
  Future<List<String>> _processingProblems(AppState st) async {
    final m = st.settings.measurement;
    // continuous acquisition without saving: nothing is processed
    if (!m.processingEnabled || m.processing.mode != ProcessingMode.qwtb || (m.continuous && !m.saveRecords)) {
      return const [];
    }
    final out = <String>[];
    final alg = m.processing.algorithmId;
    // lowest input grid frequency of interest: 40 Hz
    final periods = m.samplesCount / m.fs * 40;
    if (periods < 5) {
      out.add(tr('The record holds less than 5 mains periods: the QWTB algorithms may fail or give wrong results.'));
    } else if (alg == 'TWM-THDWFFT' && periods < 30) {
      out.add(tr('TWM-THDWFFT needs at least 30 periods of the fundamental in the record (e.g. 0.75 s at 40 Hz).'));
    }
    try {
      final info = await st.algorithmInfo(alg);
      final t = st.settings.corrections.transducers;
      bool pair(int ph) =>
          t.any((x) => x.phaseIndex == ph && x.type == TransducerType.divider) &&
          t.any((x) => x.phaseIndex == ph && x.type == TransducerType.shunt);
      if (info.hasUi && !t.any((x) => pair(x.phaseIndex))) {
        out.add(
          trf(
            '{0} computes power: it needs a voltage and a current transducer (divider and shunt) with the same phase index in HW corrections.',
            [alg],
          ),
        );
      }
    } catch (_) {
      // no calculation engine: the processing reports it itself
    }
    return out;
  }

  List<_Page> _pages(BackendFeatures f) => [
    _Page.measure,
    _Page.results,
    _Page.online,
    _Page.records,
    if (f.fileTransfer) _Page.files,
    if (f.octave) _Page.console,
  ];

  (IconData, IconData, String) _meta(_Page p) => switch (p) {
    _Page.measure => (Icons.show_chart_outlined, Icons.show_chart, tr('Measurement')),
    _Page.results => (Icons.table_chart_outlined, Icons.table_chart, tr('Results')),
    _Page.online => (Icons.speed_outlined, Icons.speed, tr('On-line analysis')),
    _Page.records => (Icons.multiline_chart_outlined, Icons.multiline_chart, tr('Records')),
    _Page.files => (Icons.folder_outlined, Icons.folder, tr('Files')),
    _Page.console => (Icons.terminal_outlined, Icons.terminal, tr('Console')),
  };

  Future<void> _start({bool setup = false}) async {
    final st = AppScope.read(context);
    if (setup) {
      final ok = await showMeasurementDialog(context);
      if (!ok || !mounted) return;
    }
    final m = st.settings.measurement;
    if (m.folder.trim().isEmpty && (m.saveRecords || !m.continuous)) {
      showError(context, tr('Select the folder for measurement data in the measurement setup first.'));
      return;
    }
    // processing that is bound to fail: say it before the measurement
    // (the first query may start the calculation engine: show it)
    st.preparing = true;
    st.touch();
    List<String> procProblems;
    try {
      procProblems = await _processingProblems(st);
    } finally {
      st.preparing = false;
      st.touch();
    }
    if (!mounted) return;
    if (procProblems.isNotEmpty) {
      final go = await confirm(
        context,
        tr('Processing setup'),
        '${procProblems.join('\n\n')}\n\n${tr('Start anyway?')}',
        ok: tr('Start'),
        cancel: tr('Cancel'),
      );
      if (!go || !mounted) return;
    }
    final mux = st.settings.digitizer.multiplexer;
    final errs = st.settings.corrections.validate(
      st.settings.digitizer.physicalChannelsCount,
      muxPaths: mux.enabled ? mux.sequence : const [],
    );
    if (errs.isNotEmpty) {
      final go = await confirm(
        context,
        tr('Transducers configuration'),
        '${tr('There are problems in the HW corrections setup:')}\n\n${errs.join('\n')}\n\n${tr('Start anyway?')}',
        ok: tr('Start'),
        cancel: tr('Cancel'),
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
            tr('Overwrite previous measurement?'),
            '${tr('The measurement folder already contains data. These files will be deleted:')}\n\n'
            '${coll.take(200).join('\n')}${coll.length > 200 ? '\n... (${coll.length})' : ''}',
            ok: tr('Delete and start'),
            cancel: tr('Cancel'),
          );
          if (!del) return;
          await st.backend.clearSession(m);
        }
      }
      await st.startMeasurement();
      if (!m.processingEnabled && _page != _Page.measure) setState(() => _page = _Page.measure);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    _toastNewErrors(st);
    final f = st.backend.features;
    final pages = _pages(f);
    if (!pages.contains(_page)) _page = _Page.measure;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          st: st,
          wide: wide,
          onStart: () => _start(),
          onSetupStart: () => _start(setup: true),
          onToggleTheme: widget.onToggleTheme,
          seenErrors: _seenErrors,
          onShowErrors: () {
            setState(() => _seenErrors = st.errorCount);
            _showErrors(st);
          },
        ),
        Expanded(child: _pageBody(_page, st)),
      ],
    );
    if (!wide) {
      return Scaffold(
        body: SafeArea(child: body),
        drawer: Drawer(
          child: SafeArea(child: _HardwareMenu(st: st, vertical: true)),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: pages.indexOf(_page),
          onDestinationSelected: (i) => setState(() => _page = pages[i]),
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          destinations: [
            for (final p in pages)
              NavigationDestination(icon: Icon(_meta(p).$1), selectedIcon: Icon(_meta(p).$2), label: _meta(p).$3),
          ],
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 14),
                const _Logo(),
                const SizedBox(height: 8),
                Expanded(
                  child: NavigationRail(
                    selectedIndex: pages.indexOf(_page),
                    onDestinationSelected: (i) => setState(() => _page = pages[i]),
                    minWidth: 92,
                    destinations: [
                      for (final p in pages)
                        NavigationRailDestination(
                          icon: Icon(_meta(p).$1),
                          selectedIcon: Icon(_meta(p).$2),
                          label: Text(_meta(p).$3, textAlign: TextAlign.center),
                        ),
                    ],
                  ),
                ),
                _HardwareMenu(st: st, vertical: false),
                const SizedBox(height: 12),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _pageBody(_Page p, AppState st) => switch (p) {
    _Page.measure => const LiveView(),
    _Page.results => const ResultsView(),
    _Page.online => const OnlineView(),
    _Page.records => const RecordViewerPanel(),
    _Page.files => const FilesPage(),
    _Page.console => ConsoleView(rawOutput: st.rawOutput),
  };

  void _showErrors(AppState st) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('Message log')),
      content: SizedBox(
        width: 640,
        child: st.errors.isEmpty
            ? Text(tr('No errors.'))
            : SingleChildScrollView(child: SelectableText(st.errors.reversed.map(trMessage).join('\n\n'))),
      ),
      actions: [
        TextButton(
          onPressed: () {
            st.clearErrors();
            Navigator.pop(c);
          },
          child: Text(tr('Clear')),
        ),
        FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('Close'))),
      ],
    ),
  );
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tr('TWM / TPQA - TracePQM'),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, cs.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.graphic_eq, color: Colors.white),
      ),
    );
  }
}

/// Header: title, measurement status and main actions.
class _Header extends StatelessWidget {
  final AppState st;
  final bool wide;
  final VoidCallback onStart;
  final VoidCallback onSetupStart;
  final VoidCallback onToggleTheme;
  final VoidCallback onShowErrors;
  final int seenErrors;

  const _Header({
    required this.st,
    required this.wide,
    required this.onStart,
    required this.onSetupStart,
    required this.onToggleTheme,
    required this.onShowErrors,
    required this.seenErrors,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = st.measuring;
    final newErrors = st.errorCount - seenErrors;
    final mode = switch (st.backend.description) {
      'browser' => tr('browser version (simulator)'),
      'local' => tr('local'),
      final d => d,
    };
    return Container(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 8, 12, 12, 12),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!wide)
                Builder(
                  builder: (c) =>
                      IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(c).openDrawer()),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('TWM · TracePQM Wattmeter'),
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(mode, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(width: 18),
              _StatusPill(st: st),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => showMeasurementDialog(context),
                icon: const Icon(Icons.tune, size: 18),
                label: Text(tr('Setup')),
              ),
              const SizedBox(width: 8),
              if (!busy && !st.processing)
                FilledButton.icon(
                  onPressed: st.preparing ? null : onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('Start')),
                )
              else
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error),
                  onPressed: () => st.stop(),
                  icon: const Icon(Icons.stop),
                  label: Text(tr('Stop')),
                ),
              PopupMenuButton<String>(
                tooltip: tr('More'),
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  switch (v) {
                    case 'setupstart':
                      onSetupStart();
                    case 'fft':
                      showFftViewer(context);
                    case 'lang':
                      st.update((s) => s.language = L10n.ru ? 'en' : 'ru');
                    case 'theme':
                      onToggleTheme();
                    case 'about':
                      showTwmAbout(context);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'setupstart',
                    enabled: !busy,
                    child: ListTile(leading: const Icon(Icons.playlist_play), title: Text(tr('Setup and start'))),
                  ),
                  PopupMenuItem(
                    value: 'fft',
                    child: ListTile(leading: const Icon(Icons.bar_chart), title: Text(tr('Algorithm spectrum'))),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'lang',
                    child: ListTile(leading: const Icon(Icons.translate), title: Text(L10n.ru ? 'English' : 'Русский')),
                  ),
                  PopupMenuItem(
                    value: 'theme',
                    child: ListTile(leading: const Icon(Icons.brightness_6), title: Text(tr('Light / dark theme'))),
                  ),
                  PopupMenuItem(
                    value: 'about',
                    child: ListTile(leading: const Icon(Icons.info_outline), title: Text(tr('About'))),
                  ),
                ],
              ),
              IconButton(
                tooltip: tr('Message log'),
                onPressed: onShowErrors,
                icon: Badge(
                  isLabelVisible: newErrors > 0,
                  label: Text('$newErrors'),
                  child: Icon(st.errors.isEmpty ? Icons.notifications_none : Icons.notifications_active_outlined),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final AppState st;
  const _StatusPill({required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = st.measuring || st.processing || st.preparing;
    final failed = !busy && st.lastRunError.isNotEmpty;
    final color = st.measuring
        ? t.colorScheme.primary
        : st.processing
        ? Colors.orange.shade700
        : failed
        ? t.colorScheme.error
        : Colors.green.shade600;
    final label = st.measuring
        ? (st.record > 0 ? '${tr('Record')} ${st.record}${st.records > 0 ? '/${st.records}' : ''}' : tr('Measuring'))
        : st.processing
        ? tr('Processing')
        : st.preparing
        ? tr('Preparing...')
        : failed
        ? tr('Error')
        : tr('Ready');
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(30)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                value: st.measuring && st.progress > 0 ? st.progress : null,
                color: color,
              ),
            )
          else
            Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          if ((busy && st.status.isNotEmpty) || failed) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                failed ? trMessage(st.lastRunError) : trMessage(st.status),
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hardware / configuration menu (TWM main panel configuration buttons).
class _HardwareMenu extends StatelessWidget {
  final AppState st;
  final bool vertical; // drawer layout
  const _HardwareMenu({required this.st, required this.vertical});

  @override
  Widget build(BuildContext context) {
    final f = st.backend.features;
    final busy = st.measuring;
    final items = <(IconData, String, VoidCallback?)>[
      (Icons.memory, tr('Digitizer'), busy ? null : () => showDigitizerDialog(context)),
      (Icons.cable, tr('HW corrections'), busy ? null : () => showCorrectionsDialog(context)),
      (Icons.calculate_outlined, tr('Batch processing'), busy ? null : () => showBatchDialog(context)),
      if (f.octave) (Icons.functions, 'Octave / Matlab', () => showOctaveDialog(context)),
      if (f.server) (Icons.lan_outlined, tr('Server'), () => showServerDialog(context)),
    ];
    if (vertical) {
      return ListView(
        children: [
          ListTile(title: Text(tr('Configuration'), style: Theme.of(context).textTheme.titleSmall)),
          for (final i in items)
            ListTile(
              leading: Icon(i.$1),
              title: Text(i.$2),
              enabled: i.$3 != null,
              onTap: i.$3 == null
                  ? null
                  : () {
                      Navigator.pop(context);
                      i.$3!();
                    },
            ),
        ],
      );
    }
    // a low window (laptop): two buttons per row, the navigation above must fit
    final compact = MediaQuery.sizeOf(context).height < 760;
    final buttons = [
      for (final i in items)
        Tooltip(
          message: i.$2,
          preferBelow: false,
          child: IconButton(
            onPressed: i.$3,
            icon: Icon(i.$1),
            visualDensity: compact ? VisualDensity.compact : null,
          ),
        ),
    ];
    return Column(
      children: [
        const Divider(indent: 16, endIndent: 16),
        if (compact) Wrap(alignment: WrapAlignment.center, children: buttons) else ...buttons,
      ],
    );
  }
}
