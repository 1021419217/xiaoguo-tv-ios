import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import 'focus_ring.dart';
import 'frosted_glass.dart';

// 历史调用点都从本文件拿玻璃常量与圆钮组件，这里统一转发，
// 让全部现有 import 保持有效，质感实现集中在 frosted_glass.dart 一处。
export 'frosted_glass.dart'
    show GlassTones, GlassOrb, FrostedGlass, GlassVariant;

/// 顶栏操作按钮：直接复用 [GlassOrb]，与全 App 圆形控件同一套磨砂玻璃质感。
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
    if (AppScope.of(context).television) {
      // 电视端保持实心底，遥控器焦点更清晰，也省掉模糊开销。
      return FocusRing(
        radius: 999,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed == null
              ? null
              : () {
                  unawaited(HapticFeedback.selectionClick());
                  onPressed!();
                },
          icon: Icon(icon, size: 20),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(42),
            minimumSize: const Size.square(42),
            padding: EdgeInsets.zero,
            backgroundColor: GlassTones.card,
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
          ),
        ),
      );
    }
    return GlassOrb(
      icon: icon,
      tooltip: tooltip,
      onTap: onPressed,
      accent: accent,
    );
  }
}
