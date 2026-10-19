import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../widgets/matrix_editor.dart';
import '../widgets/paths.dart';

// =================================================================== CSV ====

/// CSV correction matrix editor (TWM guide figure 3.18). Returns saved path.
Future<String?> showCsvEditor(BuildContext context, String path, {CsvItem? template}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AppScope(state: AppScope.read(context), child: _CsvEditor(path, template)),
);

class _CsvEditor extends StatefulWidget {
  final String path;
  final CsvItem? template;
  const _CsvEditor(this.path, this.template);
  @override
  State<_CsvEditor> createState() => _CsvEditorState();
}

class _CsvEditorState extends State<_CsvEditor> {
  late String path = widget.path;
  CsvSheet sheet = CsvSheet([
    [''],
  ]);
  bool _dirty = false;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = AppScope.read(context).backend;
    if (path.isNotEmpty && await b.exists(path)) {
      try {
        final s = CsvSheet.parse(await b.readText(path));
        setState(() {
          sheet = s;
          _msg = 'Loaded ${s.rows} x ${s.cols}';
          _dirty = false;
        });
      } catch (e) {
        setState(() => _msg = 'Error: $e');
      }
    } else if (widget.template != null) {
      setState(() {
        sheet = widget.template!.template();
        _msg = 'New file - template created.';
        _dirty = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = AppScope.of(context).backend;
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 1000,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('CSV correction matrix editor', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              PathField(
                label: 'File path',
                value: path,
                backend: b,
                extensions: const ['.csv'],
                onChanged: (v) {
                  path = v;
                  _load();
                },
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (widget.template != null)
                    OutlinedButton(
                      onPressed: () => setState(() {
                        sheet = widget.template!.template(xCount: widget.template!.is2d ? 2 : 1);
                        _dirty = true;
                      }),
                      child: const Text('Create template'),
                    ),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      sheet.fixDecimalSeparators();
                      _dirty = true;
                    }),
                    child: const Text('Convert decimal commas'),
                  ),
                  if (widget.template != null)
                    Tooltip(
                      message: widget.template!.description,
                      child: const Chip(label: Text('Format info')),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: MatrixEditor(cells: sheet.cells, height: 470, onChanged: () => setState(() => _dirty = true)),
              ),
              Row(
                children: [
                  Expanded(child: Text(_msg)),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: !_dirty && path.isNotEmpty
                        ? null
                        : () async {
                            var p = path;
                            if (p.isEmpty) {
                              final r = await browse(
                                context,
                                b,
                                title: 'Save CSV',
                                mode: BrowseMode.saveFile,
                                extensions: const ['.csv'],
                                defaultName: 'table.csv',
                              );
                              if (r == null) return;
                              p = r;
                            }
                            try {
                              await b.writeText(p, sheet.toString());
                              if (context.mounted) Navigator.pop(context, p);
                            } catch (e) {
                              setState(() => _msg = 'Save failed: $e');
                            }
                          },
                    child: const Text('SAVE'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================ transducer ====

/// Transducer correction editor (TWM guide figure 3.17). Returns the saved
/// path or null.
Future<String?> showTransducerEditor(BuildContext context, String path) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AppScope(state: AppScope.read(context), child: _TransducerEditor(path)),
);

class _TransducerEditor extends StatefulWidget {
  final String path;
  const _TransducerEditor(this.path);
  @override
  State<_TransducerEditor> createState() => _TransducerEditorState();
}

class _TransducerEditorState extends State<_TransducerEditor> {
  late String path = widget.path;
  Info info = Info();
  CsvItem item = CorrectionCatalog.transducerItems.first;
  String _msg = '';
  bool _err = false;
  int _rev = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = AppScope.read(context).backend;
    try {
      final i = path.isNotEmpty && await b.exists(path) ? Info.parse(await b.readText(path)) : _newInfo();
      setState(() {
        info = i;
        _rev++;
        _msg = 'Loaded.';
        _err = false;
      });
    } catch (e) {
      setState(() {
        _msg = '$e';
        _err = true;
      });
    }
  }

  Info _newInfo() => Info()
    ..comment('type of the correction (shunt or divider)')
    ..setText('type', 'divider')
    ..comment('name of the transducer')
    ..setText('name', '')
    ..comment('serial number of the transducer')
    ..setText('serial number', '')
    ..comment('nominal/DC ratio (V/A for shunt, Vin/Vout for divider)')
    ..setText('nominal ratio', '1')
    ..setText('nominal ratio uncertainty', '0');

  String _t(String k) => info.textOrNull(k) ?? '';
  void _set(String k, String v) => setState(() => info.setText(k, v));

  @override
  Widget build(BuildContext context) {
    final b = AppScope.of(context).backend;
    final rel = _t(item.key);
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 860,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            key: ValueKey(_rev),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Transducer correction editor', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              PathField(
                label: 'Correction file path',
                value: path,
                backend: b,
                extensions: const ['.info'],
                onChanged: (v) {
                  path = v;
                  _load();
                },
              ),
              FieldRow([
                Choice<String>(
                  label: 'Type',
                  value: _t('type').isEmpty ? 'divider' : _t('type'),
                  items: const ['divider', 'shunt'],
                  width: 140,
                  onChanged: (v) => _set('type', v),
                ),
                TextEntry(label: 'Name', value: _t('name'), width: 300, onChanged: (v) => info.setText('name', v)),
                TextEntry(
                  label: 'Serial number',
                  value: _t('serial number'),
                  width: 200,
                  onChanged: (v) => info.setText('serial number', v),
                ),
              ]),
              FieldRow([
                TextEntry(
                  label: 'Digitizer channel identifier (optional)',
                  value: _t('linked to digitizer channel'),
                  width: 360,
                  onChanged: (v) => info.setText('linked to digitizer channel', v),
                ),
                NumField(
                  label: 'Nominal ratio',
                  value: Info.parseNumber(_t('nominal ratio')) ?? 1,
                  width: 160,
                  onChanged: (v) => info.setText('nominal ratio', Info.formatNumber(v)),
                ),
                NumField(
                  label: 'Uncertainty',
                  value: Info.parseNumber(_t('nominal ratio uncertainty')) ?? 0,
                  width: 140,
                  onChanged: (v) => info.setText('nominal ratio uncertainty', Info.formatNumber(v)),
                ),
              ]),
              Group(
                title: 'Correction items (CSV tables)',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Choice<CsvItem>(
                          label: 'Correction item',
                          value: item,
                          items: CorrectionCatalog.transducerItems,
                          width: 420,
                          itemLabel: (i) => '${i.title}${(info.textOrNull(i.key) ?? '').isNotEmpty ? '  ✓' : ''}',
                          onChanged: (v) => setState(() => item = v),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'INFO',
                          icon: const Icon(Icons.info_outline),
                          onPressed: () => showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: Text(item.title),
                              content: Text(
                                '${item.description}\n\nCSV quantities: '
                                '${item.yAxis.isEmpty ? '' : 'y-axis ${item.yAxis}; '}'
                                '${item.is2d ? 'x-axis ${item.xAxis}; ' : ''}${item.quantities.join(', ')}',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextEntry(
                            key: ValueKey('${item.key}$_rev'),
                            label: 'CSV table path (relative to the INFO file)',
                            value: rel,
                            onChanged: (v) => info.setText(item.key, v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: path.isEmpty
                              ? null
                              : () async {
                                  var r = info.textOrNull(item.key) ?? '';
                                  if (r.isEmpty) r = 'csv\\${item.key.split(' ').first}.csv';
                                  final abs = joinPath(dirName(path), r);
                                  final saved = await showCsvEditor(context, abs, template: item);
                                  if (saved != null) {
                                    setState(() {
                                      info.setText(item.key, relativeTo(saved, dirName(path)));
                                      _rev++;
                                    });
                                  }
                                },
                          child: const Text('EDIT CSV'),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            info.remove(item.key);
                            _rev++;
                          }),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              MessageBox(_msg, error: _err, height: 50),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      var p = path;
                      if (p.isEmpty) {
                        final r = await browse(
                          context,
                          b,
                          title: 'Save transducer correction',
                          mode: BrowseMode.saveFile,
                          extensions: const ['.info'],
                          defaultName: 'transducer.info',
                        );
                        if (r == null) return;
                        p = r;
                      }
                      try {
                        await b.writeText(p, info.toString());
                        if (context.mounted) Navigator.pop(context, p);
                      } catch (e) {
                        setState(() {
                          _msg = '$e';
                          _err = true;
                        });
                      }
                    },
                    child: const Text('SAVE CHANGES'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================== digitizer/channel ==

/// Digitizer (or channel) correction editor (TWM guide figure 3.20).
Future<String?> showDigitizerCorrectionEditor(BuildContext context, String path, {bool channel = false}) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppScope(state: AppScope.read(context), child: _DigitizerEditor(path, channel)),
    );

class _DigitizerEditor extends StatefulWidget {
  final String path;
  final bool channel;
  const _DigitizerEditor(this.path, this.channel);
  @override
  State<_DigitizerEditor> createState() => _DigitizerEditorState();
}

class _DigitizerEditorState extends State<_DigitizerEditor> {
  late String path = widget.path;
  Info info = Info();
  late SectionItem item = _items.first;
  String _msg = '';
  bool _err = false;
  int _rev = 0;

  List<SectionItem> get _items => widget.channel ? CorrectionCatalog.channelItems : CorrectionCatalog.digitizerItems;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = AppScope.read(context).backend;
    try {
      final i = path.isNotEmpty && await b.exists(path) ? Info.parse(await b.readText(path)) : _newInfo();
      setState(() {
        info = i;
        _rev++;
        _msg = 'Loaded.';
        _err = false;
      });
    } catch (e) {
      setState(() {
        _msg = '$e';
        _err = true;
      });
    }
  }

  Info _newInfo() {
    final i = Info()
      ..comment('correction type')
      ..setText('type', widget.channel ? 'channel' : 'digitizer')
      ..setText('name', '');
    if (widget.channel) {
      i.setText('channel identifier', '');
    } else {
      i.setTextList('channel identifiers', ['']);
      i.setTextList('channel correction paths', ['']);
    }
    return i;
  }

  Info _section() {
    final s = info.sectionOrNull(item.name);
    if (s != null) return s;
    final n = Info();
    if (item.table == null) {
      n.setTextMatrix('value', [
        ['0'],
      ]);
      n.setTextMatrix('uncertainty', [
        ['0'],
      ]);
    } else {
      n.setTextMatrix('value', [
        [''],
      ]);
    }
    info.setSection(item.name, n);
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final b = st.backend;
    final sec = info.sectionOrNull(item.name);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1000,
        height: 780,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            key: ValueKey(_rev),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.channel ? 'Channel correction editor' : 'Digitizer correction editor',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              PathField(
                label: 'Correction file path',
                value: path,
                backend: b,
                extensions: const ['.info'],
                onChanged: (v) {
                  path = v;
                  _load();
                },
              ),
              FieldRow([
                TextEntry(
                  label: 'Name',
                  value: info.textOrNull('name') ?? '',
                  width: 400,
                  onChanged: (v) => info.setText('name', v),
                ),
                if (widget.channel)
                  TextEntry(
                    label: 'Channel name filter (channel identifier)',
                    value: info.textOrNull('channel identifier') ?? '',
                    width: 360,
                    onChanged: (v) => info.setText('channel identifier', v),
                  ),
              ]),
              if (!widget.channel) _channelsTable(st),
              Group(
                title: 'Correction item',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Choice<SectionItem>(
                          label: 'Correction item',
                          value: item,
                          items: _items,
                          width: 360,
                          itemLabel: (i) => '${i.title}${info.hasSection(i.name) ? '  ✓' : ''}',
                          onChanged: (v) => setState(() => item = v),
                        ),
                        IconButton(
                          tooltip: 'INFO',
                          icon: const Icon(Icons.info_outline),
                          onPressed: () => showDialog(
                            context: context,
                            builder: (_) => AlertDialog(title: Text(item.title), content: Text(item.description)),
                          ),
                        ),
                        const Spacer(),
                        if (sec == null)
                          FilledButton.tonal(
                            onPressed: () => setState(() {
                              _section();
                              _rev++;
                            }),
                            child: const Text('Create'),
                          )
                        else ...[
                          Check(
                            label: 'Disable correction',
                            value: (sec.numberOrNull('disabled') ?? 0) != 0,
                            onChanged: (v) => setState(() => v ? sec.setNumber('disabled', 1) : sec.remove('disabled')),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              info.remove(item.name);
                              _rev++;
                            }),
                            child: const Text('CLEAR'),
                          ),
                        ],
                      ],
                    ),
                    if (sec != null) _itemEditor(sec, b),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              MessageBox(_msg, error: _err, height: 50),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      var p = path;
                      if (p.isEmpty) {
                        final r = await browse(
                          context,
                          b,
                          title: 'Save correction',
                          mode: BrowseMode.saveFile,
                          extensions: const ['.info'],
                          defaultName: widget.channel ? 'channel.info' : 'digitizer.info',
                        );
                        if (r == null) return;
                        p = r;
                      }
                      try {
                        await b.writeText(p, info.toString());
                        if (context.mounted) Navigator.pop(context, p);
                      } catch (e) {
                        setState(() {
                          _msg = '$e';
                          _err = true;
                        });
                      }
                    },
                    child: const Text('SAVE CHANGES'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _channelsTable(AppState st) {
    final ids = info.textMatrixOrNull('channel identifiers') == null
        ? <String>[]
        : info.textList('channel identifiers');
    final paths = info.textMatrixOrNull('channel correction paths') == null
        ? <String>[]
        : info.textList('channel correction paths');
    final n = ids.length > paths.length ? ids.length : paths.length;
    while (ids.length < n) {
      ids.add('');
    }
    while (paths.length < n) {
      paths.add('');
    }
    void store() {
      info.setTextList('channel identifiers', ids);
      info.setTextList('channel correction paths', paths);
    }

    return Group(
      title: 'Channels (identifier - channel correction file)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < n; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(width: 30, child: Text('#${i + 1}')),
                  Expanded(
                    child: TextEntry(
                      label: 'Channel identifier',
                      value: ids[i],
                      onChanged: (v) {
                        ids[i] = v;
                        store();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextEntry(
                      label: 'Relative path of channel correction',
                      value: paths[i],
                      onChanged: (v) {
                        paths[i] = v;
                        store();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit channel correction',
                    icon: const Icon(Icons.edit),
                    onPressed: path.isEmpty
                        ? null
                        : () async {
                            final rel = paths[i].isEmpty ? 'chn${i + 1}\\channel_${i + 1}.info' : paths[i];
                            final saved = await showDigitizerCorrectionEditor(
                              context,
                              joinPath(dirName(path), rel),
                              channel: true,
                            );
                            if (saved != null) {
                              setState(() {
                                paths[i] = relativeTo(saved, dirName(path));
                                store();
                                _rev++;
                              });
                            }
                          },
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() {
                      ids.removeAt(i);
                      paths.removeAt(i);
                      store();
                      _rev++;
                    }),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => setState(() {
                  ids.add('');
                  paths.add('');
                  store();
                  _rev++;
                }),
                icon: const Icon(Icons.add),
                label: const Text('Insert'),
              ),
              TextButton.icon(
                onPressed: () async {
                  var hw = st.channelIdns;
                  if (hw.isEmpty) {
                    final r = await st.backend.testDigitizer(st.settings.digitizer);
                    hw = r.channelIdns;
                    st.channelIdns = hw;
                  }
                  setState(() {
                    info.setTextList('channel identifiers', hw);
                    final p = [for (var i = 0; i < hw.length; i++) i < paths.length ? paths[i] : ''];
                    info.setTextList('channel correction paths', p);
                    _rev++;
                  });
                },
                icon: const Icon(Icons.download),
                label: const Text('Load names from connected digitizer'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemEditor(Info sec, TwmBackend b) {
    final value =
        sec.textMatrixOrNull('value') ??
        [
          [''],
        ];
    final unc =
        sec.textMatrixOrNull('uncertainty') ??
        [
          [''],
        ];
    final attrs = sec.textMatrixOrNull('valid for attributes') == null
        ? <String>[]
        : sec.textList('valid for attributes');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          item.table == null
              ? 'Value / Uncertainty (rows: primary parameter, columns: secondary parameter; '
                    'for interchannel items one column per channel)'
              : 'Value = relative paths of CSV tables (rows: primary parameter, columns: secondary parameter)',
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Value'),
                  MatrixEditor(
                    cells: value,
                    cellWidth: item.table == null ? 110 : 260,
                    onChanged: () => sec.setTextMatrix('value', value),
                  ),
                ],
              ),
            ),
            if (item.table == null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Uncertainty'),
                    MatrixEditor(cells: unc, onChanged: () => sec.setTextMatrix('uncertainty', unc)),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (item.table != null)
          Wrap(
            spacing: 8,
            children: [
              for (var r = 0; r < value.length; r++)
                for (var c = 0; c < value[r].length; c++)
                  OutlinedButton(
                    onPressed: path.isEmpty
                        ? null
                        : () async {
                            final rel = value[r][c].isEmpty
                                ? 'csv\\${item.name.replaceAll(' ', '_')}_${r + 1}_${c + 1}.csv'
                                : value[r][c];
                            final saved = await showCsvEditor(
                              context,
                              joinPath(dirName(path), rel),
                              template: item.table,
                            );
                            if (saved != null) {
                              setState(() {
                                value[r][c] = relativeTo(saved, dirName(path));
                                sec.setTextMatrix('value', value);
                                _rev++;
                              });
                            }
                          },
                    child: Text('Edit/Create CSV [${r + 1},${c + 1}]'),
                  ),
            ],
          ),
        const SizedBox(height: 8),
        Group(
          title: 'Restrict validity by digitizer attributes (optional)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var k = 0; k < attrs.length; k++)
                Row(
                  children: [
                    Expanded(
                      child: TextEntry(
                        label: 'Attribute name (as in session header)',
                        value: attrs[k],
                        onChanged: (v) {
                          final old = attrs[k];
                          final vals = sec.textMatrixOrNull(old);
                          sec.remove(old);
                          attrs[k] = v;
                          sec.setTextList('valid for attributes', attrs);
                          if (vals != null) sec.setTextMatrix(v, vals);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextEntry(
                        label: 'Allowed values (separate by ;)',
                        value: sec.textMatrixOrNull(attrs[k]) == null ? '' : sec.textList(attrs[k]).join('; '),
                        onChanged: (v) => sec.setTextList(attrs[k], v.split(';').map((e) => e.trim()).toList()),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() {
                        sec.remove(attrs[k]);
                        attrs.removeAt(k);
                        attrs.isEmpty
                            ? sec.remove('valid for attributes')
                            : sec.setTextList('valid for attributes', attrs);
                        _rev++;
                      }),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    attrs.add('sampling mode');
                    sec.setTextList('valid for attributes', attrs);
                    _rev++;
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Add attribute'),
                ),
              ),
            ],
          ),
        ),
        for (final pn in ['primary parameter', 'secondary parameter']) _paramEditor(sec, pn),
      ],
    );
  }

  Widget _paramEditor(Info sec, String pn) {
    final p = sec.sectionOrNull(pn);
    return Group(
      title: '${pn[0].toUpperCase()}${pn.substring(1)} (optional)',
      child: p == null
          ? Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  sec.setSection(
                    pn,
                    Info()
                      ..setText('name', pn.startsWith('p') ? 'voltage ranges [V]' : 'aperture [s]')
                      ..setNumber('interpolable', 0)
                      ..setTextList('value', ['']),
                  );
                  _rev++;
                }),
                icon: const Icon(Icons.add),
                label: Text('Add $pn'),
              ),
            )
          : FieldRow([
              TextEntry(
                label: 'HW parameter name (exact header name)',
                value: p.textOrNull('name') ?? '',
                width: 300,
                onChanged: (v) => p.setText('name', v),
              ),
              Check(
                label: 'Interpolable',
                value: (p.numberOrNull('interpolable') ?? 0) != 0,
                onChanged: (v) => setState(() => p.setNumber('interpolable', v ? 1 : 0)),
              ),
              TextEntry(
                label: 'Values (separate by ;)',
                value: p.textMatrixOrNull('value') == null ? '' : p.textList('value').join('; '),
                width: 320,
                onChanged: (v) => p.setTextList('value', v.split(';').map((e) => e.trim()).toList()),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() {
                  sec.remove(pn);
                  _rev++;
                }),
              ),
            ]),
    );
  }
}
