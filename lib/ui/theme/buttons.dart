import 'package:flutter/material.dart';

import 'tokens.dart';

/// 主/次按钮的两种形态：主按钮是主题色实底胶囊（一屏一个），
/// 次按钮是同高的描边胶囊。尺寸与 [ThemeData] 里的按钮主题保持一致。
abstract final class AppButtons {
  static const height = 44.0;
  static const compact = 36.0;
  static const icon = 40.0;

  static const _dangerColor = Color(0xFFFF453A);

  static ButtonStyle primary(ColorScheme scheme) => FilledButton.styleFrom(
    backgroundColor: scheme.primary,
    foregroundColor: scheme.onPrimary,
    disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.14),
    disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.42),
    shape: const StadiumBorder(),
    elevation: 0,
    minimumSize: const Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: 24),
    textStyle: const TextStyle(
      fontSize: AppType.title,
      fontWeight: FontWeight.w700,
    ),
  );

  static ButtonStyle secondary(ColorScheme scheme) => OutlinedButton.styleFrom(
    foregroundColor: scheme.onSurface,
    side: BorderSide(color: scheme.outline),
    shape: const StadiumBorder(),
    minimumSize: const Size(0, height),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    textStyle: const TextStyle(
      fontSize: AppType.title,
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
