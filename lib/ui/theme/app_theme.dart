import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

/// 全剧TV「Lumenic 玻璃拟态」视觉 + 小果 2.0 的 pureBlack / pageTransitions。
///
/// 合并原则：保留小果 2.0 的全部公开签名（AppTheme.build 的 pureBlack 参数、
/// motion.dart 的页面转场），把全剧TV 的纯黑玻璃拟态配色、卡片、胶囊按钮、
/// 字重与半透明导航条整体叠加进来。pureBlack 打开时用 AMOLED 纯黑覆盖底色，
/// 其余分层容器仍沿用玻璃拟态的冷调深灰，二者不冲突。
abstract final class AppTheme {
  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData build(
    Color seed,
    Brightness brightness, {
    required bool television,
    bool pureBlack = false,
  }) {
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final dark = brightness == Brightness.dark;

    // 纯黑玻璃拟态：深色下用 AMOLED 纯黑底 + 分层深灰容器 + 白色细描边，
    // 模拟毛玻璃的分层通透感（真 BackdropFilter 用在有背景图的页面）。
    final glassScheme = dark
        ? base.copyWith(
            surface: const Color(0xFF0B0B0E),
            onSurface: Colors.white,
            onSurfaceVariant: const Color(0xFF8E8E93),
            outline: Colors.white.withValues(alpha: 0.14),
            outlineVariant: Colors.white.withValues(alpha: 0.09),
            surfaceContainerLowest: const Color(0xFF0A0A0C),
            surfaceContainerLow: const Color(0xFF141416),
            surfaceContainer: const Color(0xFF1C1C1E),
            surfaceContainerHigh: const Color(0xFF232326),
            surfaceContainerHighest: const Color(0xFF2A2A2E),
            surfaceDim: const Color(0xFF000000),
            surfaceBright: const Color(0xFF303036),
          )
        : base.copyWith(
            surface: Colors.white,
            surfaceContainerLowest: const Color(0xFFF7F5F8),
            surfaceContainerLow: const Color(0xFFF1EFF4),
            surfaceContainer: const Color(0xFFECEAEF),
            surfaceContainerHigh: const Color(0xFFE6E4EA),
            surfaceContainerHighest: const Color(0xFFE0DEE5),
          );

    // pureBlack 只把「底」压到纯黑，容器层级继续保留玻璃拟态的冷调深灰，
    // 这样胶囊、卡片、对话框依旧有分层，不会糊成一片。
    final scheme = pureBlack && dark
        ? glassScheme.copyWith(
            surface: Colors.black,
            surfaceDim: Colors.black,
            surfaceContainerLowest: Colors.black,
            surfaceContainerLow: const Color(0xFF0B0B0B),
            surfaceContainer: const Color(0xFF121212),
            surfaceContainerHigh: const Color(0xFF1A1A1A),
            surfaceContainerHighest: const Color(0xFF242424),
          )
        : glassScheme;

    const radius = 18.0;
    final background = dark
        ? (pureBlack ? Colors.black : const Color(0xFF0A0A0C))
        : scheme.surfaceContainerLowest;
    // 卡片用半透明磨砂：低不透明度 + 细描边，让下层内容与模糊透出来。
    final glass = CardThemeData(
      color: dark
          ? scheme.surfaceContainer.withValues(alpha: 0.72)
          : scheme.surfaceContainer,
      elevation: 0,
      margin: EdgeInsets.zero,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    );

    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      // 小果 2.0 的页面转场（电视端禁用动画）保持不变。
      pageTransitionsTheme: pageTransitions(television: television),
      cardTheme: glass,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      // 主按钮一律「白底黑字胶囊」，选中态同样靠反色，而不是主题色高亮。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: dark ? const Color(0xFFF2F2F5) : scheme.primary,
          foregroundColor: dark ? const Color(0xFF111114) : scheme.onPrimary,
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.16),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.45),
          shape: const StadiumBorder(),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: dark ? Colors.white : scheme.primary,
        linearTrackColor: Colors.white.withValues(alpha: 0.22),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        minVerticalPadding: 8,
      ),
    );

    final titled = theme.copyWith(
      textTheme: theme.textTheme.copyWith(
        headlineMedium: theme.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        headlineSmall: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
        titleLarge: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
        ),
        titleMedium: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          fontSize: 21,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark
            ? const Color(0x990A0A0C)
            : Colors.white.withValues(alpha: 0.80),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.white.withValues(alpha: 0.14),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return theme.textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
    );
    return television ? _television(titled) : titled;
  }

  static ThemeData _television(ThemeData theme) {
    final colors = theme.colorScheme;
    final button = ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.focused)
            ? colors.onSurface.withValues(alpha: 0.12)
            : null,
      ),
      minimumSize: const WidgetStatePropertyAll(Size(52, 48)),
    );
    return theme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      focusColor: colors.primary.withValues(alpha: 0.16),
      iconButtonTheme: IconButtonThemeData(style: button),
      filledButtonTheme: FilledButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(style: button),
      textButtonTheme: TextButtonThemeData(style: button),
    );
  }
}
