import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class AppButtons {
  static const height = 44.0;
  static const compact = 36.0;
  static const icon = 40.0;

  static const _dangerColor = Color(0xFFFF453A);

  static ButtonStyle primary(
    ColorScheme scheme, {
    required bool dark,
  }) => FilledButton.styleFrom(
    backgroundColor: dark ? const Color(0xFFF2F2F5) : scheme.primary,
    foregroundColor: dark ? const Color(0xFF111114) : scheme.onPrimary,
    disabledBackgroundColor: (dark ? Colors.white : scheme.onSurface)
        .withValues(alpha: 0.16),
    disabledForegroundColor: (dark ? Colors.white : scheme.onSurface)
        .withValues(alpha: 0.45),
    shape: const StadiumBorder(),
    elevation: 0,
    minimumSize: const Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: 22),
    textStyle: const TextStyle(
      fontSize: AppType.body,
      fontWeight: FontWeight.w700,
    ),
  );

  static ButtonStyle secondary(
    ColorScheme scheme, {
    required bool dark,
  }) => OutlinedButton.styleFrom(
    foregroundColor: scheme.onSurface,
    side: BorderSide(color: scheme.outline),
    shape: const StadiumBorder(),
    minimumSize: const Size(0, compact),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    textStyle: const TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    ),
  );

  static ButtonStyle tertiary(ColorScheme scheme) => TextButton.styleFrom(
    foregroundColor: scheme.onSurface,
    minimumSize: const Size(0, compact),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    shape: RoundedRectangleBorder(borderRadius: AppRadius.contentAll),
    textStyle: const TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
    ),
  );

  static ButtonStyle danger(
    ColorScheme scheme, {
    required bool dark,
  }) => tertiary(scheme).copyWith(
    foregroundColor: WidgetStatePropertyAll(
      dark ? _dangerColor : scheme.error,
    ),
  );
}
