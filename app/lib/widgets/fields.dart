import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Parses number with SI prefix or exponent: "10k", "1.5e-6", "100u".
/// Decimal comma is accepted and converted (TWM accepts only dots).
double? parseSi(String s) {
  var t = s.trim().replaceAll(',', '.').replaceAll(' ', '');
  if (t.isEmpty) return null;
  const prefixes = {'p': 1e-12, 'n': 1e-9, 'u': 1e-6, 'µ': 1e-6, 'm': 1e-3, 'k': 1e3, 'M': 1e6, 'G': 1e9};
  final last = t[t.length - 1];
  var mul = 1.0;
  if (prefixes.containsKey(last) && t.length > 1 && !t.toLowerCase().endsWith('e')) {
    mul = prefixes[last]!;
    t = t.substring(0, t.length - 1);
  }
  final v = double.tryParse(t);
  return v == null ? null : v * mul;
}

String formatNum(double v, {int digits = 10}) {
  if (v.isNaN) return 'NaN';
  if (v == v.roundToDouble() && v.abs() < 1e12) return v.toInt().toString();
  final a = v.abs();
  if (a >= 1e6 || a < 1e-3) return v.toStringAsExponential(6).replaceFirst(RegExp(r'\.?0+e'), 'e');
  var s = v.toStringAsPrecision(digits);
  if (s.contains('.') && !s.contains('e')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// Numeric entry (LabVIEW numeric control): commits on Enter / focus loss,
/// accepts SI prefixes, shows red border when invalid.
class NumField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double? min;
  final double? max;
  final bool integer;
  final String? unit;
  final double width;
  final bool enabled;
  final String? tooltip;

  const NumField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min,
    this.max,
    this.integer = false,
    this.unit,
    this.width = 160,
    this.enabled = true,
    this.tooltip,
  });

  @override
  State<NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<NumField> {
  late final TextEditingController _c = TextEditingController(text: _fmt(widget.value));
  final _focus = FocusNode();
  bool _invalid = false;

  String _fmt(double v) => widget.integer ? v.round().toString() : formatNum(v);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(NumField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) _c.text = _fmt(widget.value);
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    var v = parseSi(_c.text);
    if (v == null) {
      setState(() => _invalid = true);
      return;
    }
    if (widget.min != null && v < widget.min!) v = widget.min!;
    if (widget.max != null && v > widget.max!) v = widget.max!;
    if (widget.integer) v = v.roundToDouble();
    setState(() => _invalid = false);
    _c.text = _fmt(v);
    if (v != widget.value) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final f = SizedBox(
      width: widget.width,
      child: TextField(
        controller: _c,
        focusNode: _focus,
        enabled: widget.enabled,
        onSubmitted: (_) => _commit(),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9eE+\-.,kMGmunpµ ]'))],
        decoration: InputDecoration(
          labelText: widget.label,
          suffixText: widget.unit,
          isDense: true,
          errorText: _invalid ? 'invalid number' : null,
        ),
      ),
    );
    return widget.tooltip == null ? f : Tooltip(message: widget.tooltip!, child: f);
  }
}

/// Text entry committing on change.
class TextEntry extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final double? width;
  final int maxLines;
  final bool enabled;
  final Widget? suffix;
  final String? hint;

  const TextEntry({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.width,
    this.maxLines = 1,
    this.enabled = true,
    this.suffix,
    this.hint,
  });

  @override
  State<TextEntry> createState() => _TextEntryState();
}

class _TextEntryState extends State<TextEntry> {
  late final TextEditingController _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(TextEntry old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text && old.value != widget.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = TextField(
      controller: _c,
      enabled: widget.enabled,
      maxLines: widget.maxLines,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
        suffixIcon: widget.suffix,
      ),
    );
    return widget.width == null ? f : SizedBox(width: widget.width, child: f);
  }
}

/// Dropdown for enums / string lists.
class Choice<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T> onChanged;
  final double width;
  final bool enabled;

  const Choice({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    String Function(T)? itemLabel,
    this.width = 220,
    this.enabled = true,
  }) : itemLabel = itemLabel ?? _defaultLabel;

  static String _defaultLabel(Object? v) => v is Enum ? v.name : '$v';

  @override
  Widget build(BuildContext context) {
    final has = items.contains(value);
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<T>(
        initialValue: has ? value : null,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          for (final i in items)
            DropdownMenuItem(
              value: i,
              child: Text(itemLabel(i), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
      ),
    );
  }
}

/// Titled section of a form (replaces LabVIEW decoration frames).
class Group extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsets padding;
  const Group({super.key, required this.title, required this.child, this.padding = const EdgeInsets.all(14)});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Material(
        color: t.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Text(
                title,
                style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: t.colorScheme.primary),
              ),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// Check box with label.
class Check extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  const Check({super.key, required this.label, required this.value, required this.onChanged, this.enabled = true});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: enabled ? () => onChanged(!value) : null,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(value: value, onChanged: enabled ? (v) => onChanged(v ?? false) : null),
        Flexible(child: Text(label)),
        const SizedBox(width: 8),
      ],
    ),
  );
}

/// Status / message area of the panels (errors in red).
class MessageBox extends StatelessWidget {
  final String text;
  final bool error;
  final double height;
  const MessageBox(this.text, {super.key, this.error = false, this.height = 80});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = error ? t.colorScheme.error : (text.isEmpty ? t.colorScheme.outline : Colors.green.shade700);
    return Container(
      height: height,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: error ? t.colorScheme.errorContainer.withValues(alpha: 0.35) : t.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: c, width: 4)),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            height: 1.35,
            color: error ? t.colorScheme.error : t.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Wrap of form fields with uniform spacing.
class FieldRow extends StatelessWidget {
  final List<Widget> children;
  const FieldRow(this.children, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: children),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String ok = 'OK',
  String cancel = 'Cancel',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(cancel)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$e'),
      backgroundColor: Theme.of(context).colorScheme.error,
      duration: const Duration(seconds: 6),
    ),
  );
}

void showInfo(BuildContext context, String m) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

/// Title bar of large dialogs (optionally with tabs below).
class DialogHeader extends StatelessWidget {
  final String title;
  final PreferredSizeWidget? bottom;
  const DialogHeader(this.title, {super.key, this.bottom});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
            child: Text(title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
          ),
          ?bottom,
          Divider(height: 1, color: t.colorScheme.outlineVariant),
        ],
      ),
    );
  }
}
