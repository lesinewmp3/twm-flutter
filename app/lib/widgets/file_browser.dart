import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../l10n.dart';

enum BrowseMode { openFile, saveFile, folder }

/// File/folder selection dialog working over the backend file system (so it
/// works the same for desktop and for web clients of a remote TWM server).
Future<String?> browse(
  BuildContext context,
  TwmBackend backend, {
  String title = 'Select file',
  String initial = '',
  BrowseMode mode = BrowseMode.openFile,
  List<String> extensions = const [],
  String defaultName = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _BrowserDialog(backend, title, initial, mode, extensions, defaultName),
);

class _BrowserDialog extends StatefulWidget {
  final TwmBackend backend;
  final String title;
  final String initial;
  final BrowseMode mode;
  final List<String> extensions;
  final String defaultName;
  const _BrowserDialog(this.backend, this.title, this.initial, this.mode, this.extensions, this.defaultName);

  @override
  State<_BrowserDialog> createState() => _BrowserDialogState();
}

class _BrowserDialogState extends State<_BrowserDialog> {
  DirListing? _list;
  String? _error;
  String? _selected;
  late final TextEditingController _path = TextEditingController();
  late final TextEditingController _name = TextEditingController(text: widget.defaultName);

  @override
  void initState() {
    super.initState();
    _load(widget.initial);
  }

  Future<void> _load(String path) async {
    try {
      final l = await widget.backend.listDir(
        path,
        extensions: widget.mode == BrowseMode.folder ? const ['\u0000'] : widget.extensions,
      );
      setState(() {
        _list = l;
        _path.text = l.path;
        _error = null;
        _selected = null;
        if (widget.initial.isNotEmpty && widget.mode != BrowseMode.folder) {
          final e = l.entries.where((e) => e.path == widget.initial);
          if (e.isNotEmpty) _selected = e.first.path;
        }
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  String _join(String dir, String name) {
    final sep = _list?.separator ?? '/';
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  void _ok() {
    final l = _list;
    if (l == null) return;
    switch (widget.mode) {
      case BrowseMode.folder:
        Navigator.pop(context, _selected ?? l.path);
      case BrowseMode.openFile:
        if (_selected != null) Navigator.pop(context, _selected);
      case BrowseMode.saveFile:
        if (_name.text.trim().isNotEmpty) Navigator.pop(context, _join(l.path, _name.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 720,
        height: 480,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: tr('Up'),
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: l == null ? null : () => _load(l.parent),
                ),
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(isDense: true),
                    onSubmitted: _load,
                  ),
                ),
                if (l != null)
                  PopupMenuButton<String>(
                    tooltip: tr('Places'),
                    icon: const Icon(Icons.folder_special),
                    itemBuilder: (_) => [for (final r in l.roots) PopupMenuItem(value: r, child: Text(r))],
                    onSelected: _load,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            Expanded(
              child: l == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: l.entries.length,
                      itemBuilder: (_, i) {
                        final e = l.entries[i];
                        final sel = e.path == _selected;
                        return GestureDetector(
                          onDoubleTap: () => e.isDir
                              ? _load(e.path)
                              : (widget.mode == BrowseMode.openFile ? Navigator.pop(context, e.path) : null),
                          child: ListTile(
                            dense: true,
                            selected: sel,
                            leading: Icon(e.isDir ? Icons.folder : Icons.description_outlined),
                            title: Text(e.name),
                            trailing: e.isDir ? null : Text(_size(e.size)),
                            onTap: () => setState(() {
                              if (e.isDir && widget.mode != BrowseMode.folder) {
                                _load(e.path);
                              } else {
                                _selected = e.path;
                                if (widget.mode == BrowseMode.saveFile) _name.text = e.name;
                              }
                            }),
                            onLongPress: e.isDir ? () => _load(e.path) : null,
                            mouseCursor: SystemMouseCursors.click,
                          ),
                        );
                      },
                    ),
            ),
            if (widget.mode == BrowseMode.folder)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  tr('Click to select a folder, double-click (long press) to open it.'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
            if (widget.mode == BrowseMode.saveFile)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _name,
                  decoration: InputDecoration(labelText: tr('File name'), isDense: true),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(onPressed: _ok, child: Text(widget.mode == BrowseMode.saveFile ? 'Save' : 'Select')),
      ],
    );
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} kB';
    return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  }
}

/// Text entry with a browse button.
class PathField extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final TwmBackend backend;
  final BrowseMode mode;
  final List<String> extensions;
  final double? width;

  const PathField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.backend,
    this.mode = BrowseMode.openFile,
    this.extensions = const [],
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final f = Row(
      children: [
        Expanded(
          child: _PathText(label: label, value: value, onChanged: onChanged),
        ),
        IconButton(
          tooltip: tr('Browse...'),
          icon: const Icon(Icons.folder_open),
          onPressed: () async {
            final r = await browse(context, backend, title: label, initial: value, mode: mode, extensions: extensions);
            if (r != null) onChanged(r);
          },
        ),
      ],
    );
    return width == null ? f : SizedBox(width: width, child: f);
  }
}

class _PathText extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  const _PathText({required this.label, required this.value, required this.onChanged});
  @override
  State<_PathText> createState() => _PathTextState();
}

class _PathTextState extends State<_PathText> {
  late final _c = TextEditingController(text: widget.value);
  @override
  void didUpdateWidget(_PathText old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _c.text != widget.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    onSubmitted: widget.onChanged,
    onEditingComplete: () => widget.onChanged(_c.text),
    decoration: InputDecoration(labelText: widget.label, isDense: true),
  );
}
