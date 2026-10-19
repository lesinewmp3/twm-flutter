import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

import '../widgets/fields.dart';
import '../widgets/rows_editor.dart';

/// Multiplexer configuration panel (TWM guide figure 3.6). Edits [cfg] in
/// place.
Future<void> showMultiplexerDialog(BuildContext context, MultiplexerConfig cfg) =>
    showDialog(context: context, builder: (_) => _MuxDialog(cfg));

class _MuxDialog extends StatefulWidget {
  final MultiplexerConfig cfg;
  const _MuxDialog(this.cfg);
  @override
  State<_MuxDialog> createState() => _MuxDialogState();
}

class _MuxDialogState extends State<_MuxDialog> {
  late final MultiplexerConfig c = widget.cfg;

  @override
  Widget build(BuildContext context) {
    final names = [for (final p in c.paths) p.name];
    final primLabel = c.type == MultiplexerType.niScopePfi ? 'PFI0' : 'DTR';
    final secLabel = c.type == MultiplexerType.niScopePfi ? 'PFI1' : 'RTS';
    return AlertDialog(
      title: const Text('Multiplexer configuration'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldRow([
                Choice<MultiplexerType>(
                  label: 'Multiplexer type',
                  value: c.type,
                  items: MultiplexerType.values,
                  width: 300,
                  itemLabel: (t) => t.label,
                  onChanged: (v) => setState(() => c.type = v),
                ),
                if (c.type == MultiplexerType.niScopePfi)
                  NumField(
                    label: 'NI 5922 virtual channel index',
                    value: c.niScopeChannelIndex.toDouble(),
                    integer: true,
                    min: 0,
                    width: 220,
                    onChanged: (v) => c.niScopeChannelIndex = v.round(),
                  )
                else
                  TextEntry(label: 'Device VISA', value: c.visa, width: 220, onChanged: (v) => c.visa = v),
              ]),
              RowsEditor<MultiplexerPath>(
                title: 'Virtual channel definitions (paths)',
                rows: c.paths,
                create: () => MultiplexerPath(name: String.fromCharCode(65 + c.paths.length)),
                onChanged: () => setState(() {}),
                rowBuilder: (_, i, p) => FieldRow([
                  TextEntry(label: 'Name', value: p.name, width: 100, onChanged: (v) => setState(() => p.name = v)),
                  if (c.type == MultiplexerType.visaCommands || c.type == MultiplexerType.qpmx)
                    TextEntry(label: 'Command', value: p.command, width: 300, onChanged: (v) => p.command = v)
                  else ...[
                    Check(label: primLabel, value: p.primary, onChanged: (v) => setState(() => p.primary = v)),
                    Check(label: secLabel, value: p.secondary, onChanged: (v) => setState(() => p.secondary = v)),
                  ],
                ]),
              ),
              const SizedBox(height: 12),
              Text('Sequence definition', style: Theme.of(context).textTheme.titleSmall),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < c.sequence.length; i++)
                    InputChip(
                      label: Text(c.sequence[i]),
                      onDeleted: c.sequence.length > 1 ? () => setState(() => c.sequence.removeAt(i)) : null,
                      backgroundColor: names.contains(c.sequence[i]) ? null : Colors.red.shade100,
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Add step',
                    icon: const Icon(Icons.add_circle_outline),
                    itemBuilder: (_) => [for (final n in names) PopupMenuItem(value: n, child: Text(n))],
                    onSelected: (v) => setState(() => c.sequence.add(v)),
                  ),
                ],
              ),
              FieldRow([
                NumField(
                  label: 'Delay before switch',
                  unit: 's',
                  value: c.delayBeforeSwitch,
                  min: 0,
                  width: 180,
                  onChanged: (v) => c.delayBeforeSwitch = v,
                ),
                NumField(
                  label: 'Delay after switch',
                  unit: 's',
                  value: c.delayAfterSwitch,
                  min: 0,
                  width: 180,
                  onChanged: (v) => c.delayAfterSwitch = v,
                ),
              ]),
              const Text(
                'Enabling multiplexer multiplies virtual channels count by the sequence length, so digitizer '
                'corrections for disabled multiplexing are not compatible.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
