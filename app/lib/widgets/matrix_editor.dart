import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';

/// Spreadsheet-like editor of a string matrix (correction value matrices,
/// CSV tables). Supports Excel compatible copy/paste (tab separated) and
/// converts decimal commas on paste.
class MatrixEditor extends StatefulWidget {
  final List<List<String>> cells;
  final VoidCallback onChanged;
  final double cellWidth;
  final double? height;
  final List<String>? columnHeaders;
  final bool editable;

  const MatrixEditor({
    super.key,
    required this.cells,
    required this.onChanged,
    this.cellWidth = 110,
    this.height,
    this.columnHeaders,
    this.editable = true,
  });

  @override
  State<MatrixEditor> createState() => _MatrixEditorState();
}

class _MatrixEditorState extends State<MatrixEditor> {
  int _r = 0, _c = 0;
  final _h = ScrollController();
  final _v = ScrollController();

  List<List<String>> get m => widget.cells;
  int get cols => m.fold(0, (a, r) => r.length > a ? r.length : a);

  void _norm() {
    final n = cols;
    for (final r in m) {
      while (r.length < n) {
        r.add('');
      }
    }
  }

  void _set(int r, int c, String v) {
    while (m.length <= r) {
      m.add(List.filled(cols, '', growable: true));
    }
    while (m[r].length <= c) {
      m[r].add('');
    }
    m[r][c] = v;
    widget.onChanged();
  }

  void _menu(Offset pos, int r, int c) async {
    _r = r;
    _c = c;
    final a = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(value: 'copy', child: Text(tr('Copy all (Excel)'))),
        PopupMenuItem(value: 'paste', child: Text(tr('Paste at cell'))),
        PopupMenuDivider(),
        PopupMenuItem(value: 'insRow', child: Text(tr('Insert row'))),
        PopupMenuItem(value: 'delRow', child: Text(tr('Delete row'))),
        PopupMenuItem(value: 'insCol', child: Text(tr('Insert column'))),
        PopupMenuItem(value: 'delCol', child: Text(tr('Delete column'))),
        PopupMenuDivider(),
        PopupMenuItem(value: 'clear', child: Text(tr('Clear all'))),
      ],
    );
    if (a == null) return;
    _norm();
    switch (a) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.map((r) => r.join('\t')).join('\n')));
      case 'paste':
        final d = await Clipboard.getData(Clipboard.kTextPlain);
        final t = d?.text ?? '';
        final rows = t.replaceAll('\r', '').split('\n');
        if (rows.isNotEmpty && rows.last.isEmpty) rows.removeLast();
        for (var i = 0; i < rows.length; i++) {
          final cells = rows[i].split(rows[i].contains('\t') ? '\t' : ';');
          for (var k = 0; k < cells.length; k++) {
            var v = cells[k].trim();
            if (RegExp(r'^[+-]?\d+,\d*([eE][+-]?\d+)?$').hasMatch(v)) v = v.replaceAll(',', '.');
            _set(_r + i, _c + k, v);
          }
        }
      case 'insRow':
        m.insert(_r, List.filled(cols, '', growable: true));
      case 'delRow':
        if (m.length > 1) m.removeAt(_r);
      case 'insCol':
        for (final r in m) {
          r.insert(_c.clamp(0, r.length), '');
        }
      case 'delCol':
        if (cols > 1) {
          for (final r in m) {
            if (_c < r.length) r.removeAt(_c);
          }
        }
      case 'clear':
        m
          ..clear()
          ..add(['']);
    }
    widget.onChanged();
    setState(() {});
  }

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (m.isEmpty) m.add(['']);
    _norm();
    final n = cols;
    final t = Theme.of(context);
    Widget cell(int r, int c) => GestureDetector(
      onSecondaryTapDown: (d) => _menu(d.globalPosition, r, c),
      child: SizedBox(
        width: widget.cellWidth,
        child: _Cell(
          key: ValueKey('$r/$c/${m.length}/$n'),
          value: m[r][c],
          enabled: widget.editable,
          onChanged: (v) => _set(r, c, v),
          onFocus: () {
            _r = r;
            _c = c;
          },
        ),
      ),
    );
    final grid = Scrollbar(
      controller: _h,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _h,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: 44 + n * widget.cellWidth,
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(width: 44),
                  for (var c = 0; c < n; c++)
                    SizedBox(
                      width: widget.cellWidth,
                      child: Text(
                        widget.columnHeaders != null && c < widget.columnHeaders!.length
                            ? widget.columnHeaders![c]
                            : String.fromCharCode(65 + c % 26),
                        textAlign: TextAlign.center,
                        style: t.textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  controller: _v,
                  itemCount: m.length,
                  itemBuilder: (_, r) => Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text('${r + 1}', textAlign: TextAlign.center, style: t.textTheme.labelSmall),
                      ),
                      for (var c = 0; c < n; c++) cell(r, c),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: widget.height ?? (m.length * 34.0 + 30).clamp(80, 400), child: grid),
        if (widget.editable)
          Wrap(
            spacing: 4,
            children: [
              TextButton(onPressed: () => setState(() => _menuAction('insRowEnd')), child: Text(tr('+ row'))),
              TextButton(onPressed: () => setState(() => _menuAction('insColEnd')), child: Text(tr('+ column'))),
              TextButton(onPressed: () => setState(() => _menuAction('delRowEnd')), child: Text(tr('- row'))),
              TextButton(onPressed: () => setState(() => _menuAction('delColEnd')), child: Text(tr('- column'))),
              Text(tr('  right click a cell for copy/paste'), style: TextStyle(fontSize: 11)),
            ],
          ),
      ],
    );
  }

  void _menuAction(String a) {
    _norm();
    switch (a) {
      case 'insRowEnd':
        m.add(List.filled(cols, '', growable: true));
      case 'insColEnd':
        for (final r in m) {
          r.add('');
        }
      case 'delRowEnd':
        if (m.length > 1) m.removeLast();
      case 'delColEnd':
        if (cols > 1) {
          for (final r in m) {
            r.removeLast();
          }
        }
    }
    widget.onChanged();
  }
}

class _Cell extends StatefulWidget {
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onFocus;
  const _Cell({super.key, required this.value, required this.enabled, required this.onChanged, required this.onFocus});
  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  late final _c = TextEditingController(text: widget.value);
  final _f = FocusNode();

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (_f.hasFocus) widget.onFocus();
    });
  }

  @override
  void didUpdateWidget(_Cell old) {
    super.didUpdateWidget(old);
    if (!_f.hasFocus && widget.value != _c.text) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(1),
    child: TextField(
      controller: _c,
      focusNode: _f,
      enabled: widget.enabled,
      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      ),
      onChanged: widget.onChanged,
    ),
  );
}
