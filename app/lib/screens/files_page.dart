import 'package:flutter/material.dart';
import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

import '../backend/file_transfer.dart';
import '../l10n.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/fields.dart';

/// Browser storage manager (web version): measurement sessions and
/// correction files stored in the browser, upload/download as TWM files.
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  List<FileEntry> _sessions = [];
  DirListing? _corr;
  String _corrPath = BrowserBackend.correctionsFolder;
  bool _busy = false;

  BrowserBackend? get _b {
    final b = AppScope.read(context).backend;
    return b is BrowserBackend ? b : null;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context).resultsVersion; // refresh after new measurements
  }

  Future<void> _reload() async {
    final st = AppScope.read(context);
    final l = await st.backend.listDir(BrowserBackend.sessionsFolder);
    final sessions = <FileEntry>[];
    for (final e in l.entries.where((e) => e.isDir)) {
      if (await st.backend.exists('${e.path}/session.info')) sessions.add(e);
    }
    final c = await st.backend.listDir(_corrPath);
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _corr = c;
      });
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _uploadSessions() async {
    final files = await pickFiles(accept: '.zip');
    await _run(() async {
      var n = 0;
      for (final f in files) {
        n += (await _b!.importZip(f.$2, BrowserBackend.sessionsFolder)).length;
      }
      if (mounted) showInfo(context, trf('{0} measurement session(s) imported.', [n]));
    });
  }

  Future<void> _uploadCorrections() async {
    final files = await pickFiles(accept: '.zip,.info,.csv');
    await _run(() async {
      for (final f in files) {
        if (f.$1.toLowerCase().endsWith('.zip')) {
          await _b!.importZip(f.$2, _corrPath);
        } else {
          await _b!.upload('$_corrPath/${f.$1}', f.$2);
        }
      }
      if (mounted) showInfo(context, trf('{0} file(s) uploaded to {1}.', [files.length, _corrPath]));
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final b = _b;
    if (b == null) return Center(child: Text(tr('Files are managed on the computer running TWM.')));
    final store = b.store;
    final used = store is MemoryFileStore ? store.files.values.fold<int>(0, (s, f) => s + f.length) : 0;
    final t = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          tr(
            'All data of the browser version are stored only in this browser. Download measurements to keep them '
            'or to process them in the desktop TWM (the format is identical).',
          ),
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Panel(
          title: tr('Measurement sessions'),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            TextButton.icon(
              onPressed: _uploadSessions,
              icon: const Icon(Icons.upload_file),
              label: Text(tr('Upload ZIP')),
            ),
          ],
          child: _sessions.isEmpty
              ? Padding(padding: const EdgeInsets.all(8), child: Text(tr('No measurements yet.')))
              : Column(
                  children: [
                    for (final s in _sessions)
                      ListTile(
                        leading: const Icon(Icons.folder_special_outlined),
                        title: Text(s.name),
                        subtitle: Text(s.path),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: tr('Show results'),
                              icon: const Icon(Icons.table_chart_outlined),
                              onPressed: () {
                                st.viewedSession = '${s.path}/session.info';
                                st.resultsVersion++;
                                st.touch();
                                showInfo(context, tr('Session selected - open the Results or Records page.'));
                              },
                            ),
                            IconButton(
                              tooltip: tr('Download ZIP'),
                              icon: const Icon(Icons.download),
                              onPressed: () =>
                                  _run(() async => downloadFile('${s.name}.zip', await b.exportZip(s.path))),
                            ),
                            IconButton(
                              tooltip: tr('Delete'),
                              icon: Icon(Icons.delete_outline, color: t.colorScheme.error),
                              onPressed: () async {
                                if (await confirm(
                                  context,
                                  tr('Delete measurement?'),
                                  s.path,
                                  ok: tr('Delete'),
                                  cancel: tr('Cancel'),
                                )) {
                                  await _run(() => b.delete(s.path));
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: tr('Correction files'),
          actions: [
            TextButton.icon(
              onPressed: _uploadCorrections,
              icon: const Icon(Icons.upload_file),
              label: Text(tr('Upload files')),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: tr('Up'),
                    onPressed: _corrPath == BrowserBackend.correctionsFolder
                        ? null
                        : () {
                            _corrPath = _corr?.parent ?? BrowserBackend.correctionsFolder;
                            _reload();
                          },
                  ),
                  Expanded(child: Text(_corrPath, style: t.textTheme.bodyMedium)),
                ],
              ),
              for (final e in _corr?.entries ?? const <FileEntry>[])
                ListTile(
                  dense: true,
                  leading: Icon(e.isDir ? Icons.folder_outlined : Icons.description_outlined),
                  title: Text(e.name),
                  trailing: e.isDir
                      ? null
                      : Wrap(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.download, size: 18),
                              onPressed: () async => downloadFile(e.name, await b.download(e.path)),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, size: 18, color: t.colorScheme.error),
                              onPressed: () => _run(() => b.delete(e.path)),
                            ),
                          ],
                        ),
                  onTap: e.isDir
                      ? () {
                          _corrPath = e.path;
                          _reload();
                        }
                      : null,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: tr('Browser storage'),
          child: Row(
            children: [
              Expanded(child: Text('${tr('Used')}: ${(used / 1048576).toStringAsFixed(1)} MB')),
              OutlinedButton.icon(
                icon: Icon(Icons.restart_alt, color: t.colorScheme.error),
                label: Text(tr('Delete all data')),
                onPressed: () async {
                  if (!await confirm(
                    context,
                    tr('Delete all data?'),
                    tr('All measurements and uploaded corrections stored in this browser will be deleted.'),
                    ok: tr('Delete'),
                    cancel: tr('Cancel'),
                  )) {
                    return;
                  }
                  await _run(() async {
                    await b.delete(BrowserBackend.sessionsFolder);
                    st.currentSession = '';
                    st.viewedSession = '';
                    st.lastWaveform = null;
                    st.touch();
                  });
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
