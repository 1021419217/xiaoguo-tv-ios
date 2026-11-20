import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import 'focus_ring.dart';

/// 固定「中性冷灰玻璃」视觉常量，按短剧之家截图逐点取色实测。
/// 全 App 的圆形 / 胶囊 / 卡片控件共用这一套，保证质感与色系完全一致，
/// 且不含任何动态取色，界面不会随海报或视频帧变化。
abstract final class GlassTones {
  static const Color background = Color(0xFF1B1D23);
  static const Color card = Color(0xFF2E3138);
  static const Color cell = Color(0xFF1A1A1C);
  static const Color orbCenter = Color(0xFF2A2B2F);
  static const Color orbEdge = Color(0xFF161618);
  static const Color orbSelected = Color(0xFF4B4B4D);
  static const Color hairline = Color(0xFF4A4A4C);

  /// 短剧之家那种「隐约能看到一圈白边」：1px、低不透明度的亮灰描边。
  static BorderSide edge([double opacity = 0.72]) =>
      BorderSide(color: hairline.withValues(alpha: opacity), width: 1);
}

/// 短剧之家式圆形玻璃钮。
///
/// 关键不是「半透明玻璃」，而是三层一起做：
///   1) 径向渐变，中心亮、边缘压暗 → 球面鼓起感；
///   2) 1px 细亮描边 → 隐约白边，把圆从背景里立出来；
///   3) 白色粗实心图标 → 饱满，不细瘦。
/// 最底下垫一层轻模糊，让背后的封面微微透出底色，但不改变色相。
/// 所有点击统一带一次轻震，补齐之前新控件丢掉的触感。
class GlassOrb extends StatelessWidget {
  const GlassOrb({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 42,
    this.iconSize,
    this.tooltip,
    this.selected = false,
    this.accent = false,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double? iconSize;
  final String? tooltip;
  final bool selected;
  final bool accent;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = iconColor ?? (dark ? Colors.white : const Color(0xFF14161A));
    final center = selected
        ? GlassTones.orbSelected
        : (accent ? const Color(0xFF37383D) : GlassTones.orbCenter);
    final edge = selected ? const Color(0xFF333437) : GlassTones.orbEdge;

    Widget orb = ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(0, -0.38),
              radius: 0.98,
              colors: [
                center.withValues(alpha: 0.88),
                edge.withValues(alpha: 0.94),
              ],
              stops: const [0.0, 1.0],
            ),
            border: Border.all(
              color: GlassTones.hairline.withValues(
                alpha: selected ? 0.95 : 0.72,
              ),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: iconSize ?? size * 0.46,
            weight: 700,
            color: ink.withValues(alpha: onTap == null ? 0.38 : 0.96),
            shadows: const [Shadow(color: Color(0x33FFFFFF), blurRadius: 2)],
          ),
        ),
      ),
    );

    Widget result = FocusRing(
      radius: 999,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap == null
              ? null
              : () {
                  unawaited(HapticFeedback.selectionClick());
                  onTap!();
                },
          splashColor: Colors.white.withValues(alpha: 0.10),
          child: orb,
        ),
      ),
    );
    if (tooltip != null) {
      result = Tooltip(
        message: tooltip!,
        child: Semantics(button: true, label: tooltip, child: result),
      );
    }
    return result;
  }
}

/// 顶栏操作按钮：直接复用 [GlassOrb]，与全 App 圆形控件同一套质感。
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
          onPressed: onPressed,
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
