import 'package:flutter/material.dart';

/// The Vesopa palette, taken from the brand mark: a magenta/purple "V" on
/// black.
abstract class Pos {
  static const brand = Color(0xFFA4308F);
  static const brandSoft = Color(0xFFF4E6F2);
  static const brandDark = Color(0xFF3A1435);

  /// Title bar, drawer header, and the splash background.
  static const chrome = Color(0xFF14121A);

  static const red = Color(0xFFE8412C);
  static const blue = Color(0xFF4BA3F5);
  static const teal = Color(0xFF1E9184);
  static const amber = Color(0xFFF5B301);
  static const orange = Color(0xFFF4633A);
  static const purple = Color(0xFFA435B0);
  static const cyan = Color(0xFF3FBBD6);
  static const green = Color(0xFF7CBB3F);
  static const indigo = Color(0xFF2E3A8C);

  /// A per-button colour from the back office, e.g. "#4BA3F5". Returns null for
  /// anything unset or malformed, so a bad value falls back to the department
  /// colour rather than crashing the till.
  static Color? parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    var value = hex.replaceFirst('#', '').trim();
    if (value.length == 6) value = 'FF$value';
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? null : Color(parsed);
  }

  /// Each category keeps its own colour, so a clerk learns the screen by colour
  /// rather than by reading every label.
  static Color categoryColor(String name) {
    switch (name.toLowerCase()) {
      case 'tea':
        return teal;
      case 'wines':
        return purple;
      case 'spirits':
        return indigo;
      case 'cocktails':
        return orange;
      case 'coffee':
        return const Color(0xFF8D5524);
      case 'bottles':
        return const Color(0xFF2E9E5B);
      case 'food':
        return orange;
      default:
        return blue;
    }
  }
}

/// Surfaces that differ between light and dark. Reading these from the theme
/// rather than hardcoding white keeps the till legible in a dim bar as well as
/// a bright cafe.
extension PosColors on ThemeData {
  bool get isDark => brightness == Brightness.dark;

  /// The panel behind the basket and the category rail.
  Color get posSurface => isDark ? const Color(0xFF1C1922) : Colors.white;

  /// The totals strip.
  Color get posTotals => isDark ? const Color(0xFF262230) : const Color(0xFFEDEAEE);

  /// Hairlines between panels.
  Color get posLine => isDark ? const Color(0xFF332E3C) : const Color(0xFFD9D4DA);

  /// The action bar along the bottom.
  Color get posActionBar => isDark ? const Color(0xFF0F0D14) : const Color(0xFF16110F);

  /// The navigation rail.
  Color get posRail => isDark ? const Color(0xFF17141D) : const Color(0xFFFAF7FA);

  /// An idle table on the floor plan.
  Color get posIdle => isDark ? const Color(0xFF2A2633) : const Color(0xFFECEAEE);
}

ThemeData buildPosTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;

  final scheme = ColorScheme.fromSeed(
    seedColor: Pos.brand,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF121017) : Colors.white,
    // The till chrome is always the dark brand bar, in both themes — a white
    // app bar with white text (the reported bug) came from Material3 tinting an
    // untinted AppBar. Pin it.
    appBarTheme: const AppBarTheme(
      backgroundColor: Pos.chrome,
      foregroundColor: Colors.white,
      elevation: 0,
      iconTheme: IconThemeData(color: Colors.white),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF1C1922) : Colors.white,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}
