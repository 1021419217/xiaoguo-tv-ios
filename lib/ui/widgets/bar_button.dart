import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../theme/poster_palette.dart';
import 'focus_ring.dart';

/// 顶栏操作按钮：单层低对比磨砂圆钮（40×40）。
///
/// 只用「一层圆形玻璃 + 一圈极细描边 + 图标」，不再叠加渐变、顶部内高光、
/// 外发光等多重圆形装饰：那些层在浅色详情页（背景取自封面）上会叠出好几个
/// 同心圆边界，尤其深色内高光会在圆里糊出一块深色半圆，看起来像图标重影。
/// [accent] 仅把玻璃调亮一点点区分主次，不额外加发光。
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.accent = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 主操作强调：略微提亮玻璃，不产生额外图层或发光。
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (AppScope.of(context).television) {
      // 电视端保持实心底，遥控器焦点更清晰，也省掉模糊开销。
      return FocusRing(
        radius: 999,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(42),
            minimumSize: const Size.square(42),
            padding: EdgeInsets.zero,
            backgroundColor: colors.surfaceContainerHigh,
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
          ),
        ),
      );
    }

    final dark = theme.brightness == Brightness.dark;
    // 玻璃底跟随当前海报色相（短剧之家的圆钮就是透出背后封面的颜色）；
    // 没取到色 / 关闭跟随时退回中性白玻璃。图标始终用反色，保证可读。
    final tint = PosterPalette.instance.buttonTint ??
        (dark ? Colors.white : colors.onSurface);
    final ink = dark ? Colors.white : colors.onSurface;
    final inactive = onPressed == null;

    // 短剧之家玻璃档位：填充约 0.20 alpha（截图实测），比原来 0.10 更实、
    // 更能透出背后封面却仍有清晰圆形边界；描边 0.28 让圆在花哨海报上立得住。
    // 仍是单层圆 + 一层底色 + 一圈极细描边，不叠加内高光 / 外发光。
    final fill = tint.withValues(
      alpha: inactive
          ? 0.06
          : accent
          ? 0.26
          : 0.20,
    );
    final hairline = tint.withValues(
      alpha: inactive
          ? 0.10
          : accent
          ? 0.34
          : 0.28,
    );

    return FocusRing(
      radius: 999,
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashColor: ink.withValues(alpha: 0.10),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: fill,
                      border: Border.all(color: hairline, width: 0.8),
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: ink.withValues(alpha: inactive ? 0.38 : 0.92),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
