import 'package:flutter/material.dart';

/// Avatar styling for project list items: a colored circle with the first
/// letter of the project name in white.
///
/// The color is picked deterministically from the project label (a stable
/// hash, not a random roll) so a project's color doesn't reshuffle on every
/// rebuild or app start — it just *looks* randomly assigned.
///
/// Palette entries are all dark/saturated enough (relative luminance ≤ 0.18,
/// contrast with white ≥ 4.5) that white letters stay readable; guarded by
/// project_avatar_test.dart.
const palette = <Color>[
  Color(0xFF1D4ED8), // blue-700
  Color(0xFF4338CA), // indigo-700
  Color(0xFF6D28D9), // violet-700
  Color(0xFF7E22CE), // purple-700
  Color(0xFFA21CAF), // fuchsia-700
  Color(0xFFBE185D), // pink-700
  Color(0xFFBE123C), // rose-700
  Color(0xFFB91C1C), // red-700
  Color(0xFFC2410C), // orange-700
  Color(0xFFB45309), // amber-700
  Color(0xFF15803D), // green-700
  Color(0xFF047857), // emerald-700
  Color(0xFF0F766E), // teal-700
  Color(0xFF0E7490), // cyan-700
  Color(0xFF0369A1), // sky-700
  Color(0xFF6D4C41), // brown-600
  Color(0xFF475569), // slate-600
];

/// Stable FNV-1a hash — String.hashCode is not guaranteed stable across
/// runs, and the color assignment must not change between launches.
int _stableHash(String s) {
  var hash = 0x811C9DC5;
  for (final unit in s.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// The background color assigned to [label].
Color projectAvatarColor(String label) =>
    palette[_stableHash(label) % palette.length];

/// The letter shown in the circle: first character of the label, uppercased
/// (a no-op for non-Latin scripts, which is fine — the character itself is
/// shown). Falls back to '?' for empty labels.
String projectAvatarLetter(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.substring(0, 1).toUpperCase();
}
