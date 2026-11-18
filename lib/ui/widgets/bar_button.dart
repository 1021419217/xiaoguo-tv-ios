import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'focus_ring.dart';

enum BarTone { neutral, danger }

/// 顶栏操作按钮：单层低对比磨砂圆钮（默认 40，顶栏动作用 38）。
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
    this.size = 40,
    this.tone = BarTone.neutral,
    this.focusNode,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 主操作强调：略微提亮玻璃，不产生额外图层或发光。
  final bool accent;
  final double size;
  final BarTone tone;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final danger = tone == BarTone.danger;
    if (AppScope.of(context).television) {
      // 电视端保持实心底，遥控器焦点更清晰，也省掉模糊开销。
      return FocusRing(
        radius: 999,
        child: IconButton(
          tooltip: tooltip,
          focusNode: focusNode,
          onPressed: onPressed,
          icon: Icon(icon, size: size * 0.5),
          style: IconButton.styleFrom(
            fixedSize: Size.square(size),
            minimumSize: Size.square(size),
            padding: EdgeInsets.zero,
            backgroundColor: colors.surfaceContainerHigh,
            foregroundColor: danger ? colors.error : Colors.white,
            shape: const CircleBorder(),
          ),
        ),
      );
    }

    final dark = theme.brightness == Brightness.dark;
    final tint = danger ? colors.error : (dark ? Colors.white : colors.onSurface);
    final ink = danger ? colors.error : (dark ? Colors.white : colors.onSurface);
    final inactive = onPressed == null;

    // 单层均匀玻璃：一个圆、一层底色、一圈极细描边，没有第二层圆形边界。
    final fill = tint.withValues(
      alpha: inactive
          ? 0.04
          : danger
          ? 0.10
          : accent
          ? 0.15
          : 0.08,
    );
    final hairline = tint.withValues(
      alpha: inactive
          ? 0.07
          : danger
          ? 0.24
          : accent
          ? 0.22
          : 0.14,
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
              focusNode: focusNode,
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashColor: ink.withValues(alpha: 0.10),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    width: size,
                    height: size,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: fill,
                      border: Border.all(color: hairline, width: 0.8),
                    ),
                    child: Icon(
                      icon,
                      size: size * 0.48,
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
