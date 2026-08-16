import 'package:flutter/material.dart';

/// Material 3 theme with a developer-tool feel: dark by default, follows the
/// system, and uses a neutral blue-grey seed so message content stays the
/// focal color.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3B82F6),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0.5,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: scheme.surfaceContainerLow,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Colors used by conversation rows to distinguish role.
class RowColors {
  static Color assistant(BuildContext c) => Theme.of(c).colorScheme.onSurface;
  static Color reasoning(BuildContext c) =>
      Theme.of(c).colorScheme.onSurfaceVariant;
  static Color user(BuildContext c) =>
      Theme.of(c).colorScheme.primary.withValues(alpha: 0.92);
  static Color tool(BuildContext c) =>
      Theme.of(c).colorScheme.secondary.withValues(alpha: 0.9);
}
