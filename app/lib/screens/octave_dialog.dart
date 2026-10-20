import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../l10n.dart';

/// Processing environment configuration (TWM guide figure 3.4) with the
/// GNU Octave package assistant (figure 3.5).
Future<void> showOctaveDialog(BuildContext context) => showDialog(
  context: context,
  builder: (_) => AppScope(state: AppScope.read(context), child: const _OctaveDialog()),
);

class _OctaveDialog extends StatefulWidget {
  const _OctaveDialog();
  @override
  State<_OctaveDialog> createState() => _OctaveDialogState();
}

class _OctaveDialogState extends State<_OctaveDialog> {
  late OctaveConfig cfg = OctaveConfig.fromJson(AppScope.read(context).settings.octave.toJson());
  OctaveStatus? _status;
  String _msg = '';
  bool _err = false;
  bool _busy = false;
  String? _selInstalled;
  String? _selLoad;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).backend.octaveStatus().then((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  void _save() => AppScope.read(context).update((s) => s.octave = OctaveConfig.fromJson(cfg.toJson()));

  Future<void> _run(String what, Future<String> Function() f) async {
    setState(() {
      _busy = true;
      _msg = '$what...';
      _err = false;
    });
    try {
      final m = await f();
      setState(() => _msg = m);
    } catch (e) {
      setState(() {
        _msg = '$e';
        _err = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _restart() async {
    _save();
    final s = await AppScope.read(context).backend.octaveRestart(cfg);
    setState(() => _status = s);
    if (s.error.isNotEmpty) throw s.error;
    return '${s.isOctave ? 'GNU Octave' : 'Matlab'} ${s.version} running.\n'
        'Loaded packages: ${s.loadedPackages.join(', ')}'
        '${s.failedPackages.isEmpty ? '' : '\nFAILED to load: ${s.failedPackages.join(', ')}'}\n'
        'QWTB found: ${s.hasQwtb ? 'yes' : 'NO - check QWTB path'}';
  }

  Future<String> _testQwtb() async {
    _save();
    final st = AppScope.read(context);
    await st.backend.octaveStart(cfg);
    final a = await st.backend.algorithms();
    return 'QWTB OK - ${a.length} TWM compatible algorithms:\n${a.map((e) => '  ${e.id}: ${e.name}').join('\n')}';
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final b = st.backend;
    final installed = _status?.installedPackages ?? const <String>[];
    final isMatlab = cfg.engine == CalcEngine.matlab;
    return AlertDialog(
      title: Text(tr('GNU Octave / Matlab configuration')),
      content: SizedBox(
        width: 820,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Check(
                label: tr('Enable Matlab script mode (otherwise GNU Octave)'),
                value: isMatlab,
                onChanged: (v) => setState(() => cfg.engine = v ? CalcEngine.matlab : CalcEngine.octave),
              ),
              if (!isMatlab)
                PathField(
                  label: tr('GNU Octave binary path (folder with octave-cli or the binary; empty = system PATH)'),
                  value: cfg.octavePath,
                  backend: b,
                  mode: BrowseMode.openFile,
                  onChanged: (v) => setState(() => cfg.octavePath = v),
                )
              else
                PathField(
                  label: tr('Matlab binary (empty = system PATH)'),
                  value: cfg.matlabPath,
                  backend: b,
                  onChanged: (v) => setState(() => cfg.matlabPath = v),
                ),
              Wrap(
                children: [
                  Check(
                    label: tr('Always clear function cache (debug only)'),
                    value: cfg.clearCache,
                    onChanged: (v) => setState(() => cfg.clearCache = v),
                  ),
                  Check(
                    label: tr('Show console window (see Console tab)'),
                    value: cfg.showConsole,
                    onChanged: (v) => setState(() => cfg.showConsole = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PathField(
                label: tr('TWM processing scripts (octprog) folder'),
                value: cfg.octprogPath,
                backend: b,
                mode: BrowseMode.folder,
                onChanged: (v) => setState(() => cfg.octprogPath = v),
              ),
              const SizedBox(height: 8),
              PathField(
                label: tr('QWTB toolbox root path (default: octprog/qwtb)'),
                value: cfg.qwtbPath,
                backend: b,
                mode: BrowseMode.folder,
                onChanged: (v) => setState(() => cfg.qwtbPath = v),
              ),
              if (!isMatlab)
                Group(
                  title: tr('Package assistant'),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _pkgList(
                          'Installed packages',
                          installed,
                          _selInstalled,
                          (v) => setState(() => _selInstalled = v),
                        ),
                      ),
                      Column(
                        children: [
                          const SizedBox(height: 40),
                          IconButton(
                            tooltip: tr('Load on startup'),
                            icon: const Icon(Icons.arrow_forward),
                            onPressed: _selInstalled == null || cfg.packages.contains(_selInstalled)
                                ? null
                                : () => setState(() => cfg.packages.add(_selInstalled!)),
                          ),
                          IconButton(
                            tooltip: tr('Do not load'),
                            icon: const Icon(Icons.arrow_back),
                            onPressed: _selLoad == null
                                ? null
                                : () => setState(() {
                                    cfg.packages.remove(_selLoad);
                                    _selLoad = null;
                                  }),
                          ),
                        ],
                      ),
                      Expanded(
                        child: _pkgList(
                          'Packages to load',
                          cfg.packages,
                          _selLoad,
                          (v) => setState(() => _selLoad = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 170,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final f = await browse(
                                        context,
                                        b,
                                        title: tr('Select package (*.tar.gz)'),
                                        extensions: const ['.tar.gz', '.tgz'],
                                      );
                                      if (f == null) return;
                                      await _run('Installing package', () async {
                                        await b.octaveInstallPackage(f);
                                        return 'Package installed. Reload packages and move it to the load list.';
                                      });
                                    },
                              child: Text(tr('Install packages')),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _busy ? null : () => _run('Reloading', _restart),
                              child: Text(tr('Reload packages')),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              MessageBox(_msg, error: _err, height: 150),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: _busy ? null : () => _run('Starting', _restart), child: Text(tr('Restart'))),
        OutlinedButton(onPressed: _busy ? null : () => _run('Testing QWTB', _testQwtb), child: Text(tr('TEST QWTB'))),
        const SizedBox(width: 24),
        FilledButton(
          onPressed: () {
            _save();
            Navigator.pop(context);
          },
          child: Text(tr('OK')),
        ),
      ],
    );
  }

  Widget _pkgList(String title, List<String> items, String? sel, ValueChanged<String> onSel) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.labelLarge),
      Container(
        height: 150,
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor)),
        child: ListView(
          children: [
            for (final p in items) ListTile(dense: true, title: Text(p), selected: p == sel, onTap: () => onSel(p)),
          ],
        ),
      ),
    ],
  );
}
