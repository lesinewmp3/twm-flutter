import 'package:flutter/material.dart';

/// Editable list of rows with add / remove / move buttons (the LabVIEW
/// tables with coloured reorder icons in TWM configuration panels).
class RowsEditor<T> extends StatelessWidget {
  final String title;
  final List<T> rows;
  final T Function() create;
  final Widget Function(BuildContext context, int index, T row) rowBuilder;
  final VoidCallback onChanged;
  final int minRows;
  final int? maxRows;

  const RowsEditor({
    super.key,
    required this.title,
    required this.rows,
    required this.create,
    required this.rowBuilder,
    required this.onChanged,
    this.minRows = 1,
    this.maxRows,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(title, style: t.textTheme.titleSmall),
            const Spacer(),
            TextButton.icon(
              onPressed: maxRows != null && rows.length >= maxRows!
                  ? null
                  : () {
                      rows.add(create());
                      onChanged();
                    },
              icon: const Icon(Icons.add),
              label: const Text('Add row'),
            ),
          ],
        ),
        for (var i = 0; i < rows.length; i++)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: i.isEven ? t.colorScheme.surfaceContainerLow : t.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                SizedBox(width: 28, child: Text('#${i + 1}', style: t.textTheme.labelMedium)),
                Expanded(child: rowBuilder(context, i, rows[i])),
                IconButton(
                  tooltip: 'Move up',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: i == 0
                      ? null
                      : () {
                          final r = rows.removeAt(i);
                          rows.insert(i - 1, r);
                          onChanged();
                        },
                ),
                IconButton(
                  tooltip: 'Move down',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: i == rows.length - 1
                      ? null
                      : () {
                          final r = rows.removeAt(i);
                          rows.insert(i + 1, r);
                          onChanged();
                        },
                ),
                IconButton(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline, size: 18, color: t.colorScheme.error),
                  onPressed: rows.length <= minRows
                      ? null
                      : () {
                          rows.removeAt(i);
                          onChanged();
                        },
                ),
              ],
            ),
          ),
      ],
    );
  }
}
