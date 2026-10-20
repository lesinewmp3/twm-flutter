import 'package:flutter/material.dart';

/// Light modern theme of the application (dark variant kept for the
/// theme toggle).
class TwmTheme {
  static const seed = Color(0xFF3557D6);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final cs =
        ColorScheme.fromSeed(
          seedColor: seed,
          brightness: b,
          surface: dark ? const Color(0xFF14171F) : Colors.white,
        ).copyWith(
          surfaceContainerLowest: dark ? const Color(0xFF0F1218) : Colors.white,
          surfaceContainerLow: dark ? const Color(0xFF181C25) : const Color(0xFFF7F8FB),
          surfaceContainer: dark ? const Color(0xFF1C212B) : const Color(0xFFF1F3F8),
          surfaceContainerHigh: dark ? const Color(0xFF222834) : const Color(0xFFE9ECF3),
          outlineVariant: dark ? const Color(0xFF2E3442) : const Color(0xFFE1E5EE),
        );
    final radius = BorderRadius.circular(10);
    return ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: dark ? const Color(0xFF0F1218) : const Color(0xFFF4F6FA),
      dividerColor: cs.outlineVariant,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cs.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: dark ? const Color(0xFF181C25) : const Color(0xFFF7F8FB),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: cs.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: radius),
          side: BorderSide(color: cs.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cs.surface,
        indicatorColor: cs.primaryContainer,
        selectedIconTheme: IconThemeData(color: cs.onPrimaryContainer),
        labelType: NavigationRailLabelType.all,
      ),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      tabBarTheme: TabBarThemeData(dividerColor: cs.outlineVariant),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }
}

/// White card section with title (replaces LabVIEW decoration frames).
class Panel extends StatelessWidget {
  final String? title;
  final Widget child;
  final List<Widget> actions;
  final EdgeInsets padding;
  final bool expand;
  const Panel({
    super.key,
    this.title,
    required this.child,
    this.actions = const [],
    this.padding = const EdgeInsets.all(16),
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final body = Padding(padding: padding, child: child);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (title != null || actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  if (title != null)
                    Text(title!, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  ...actions,
                ],
              ),
            ),
          if (expand) Expanded(child: body) else body,
        ],
      ),
    );
  }
}

/// Small value tile (key numbers on the measurement page).
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color? accent;
  const StatTile(this.label, this.value, this.unit, {super.key, this.accent});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: 170,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: accent ?? t.colorScheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(unit, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}
